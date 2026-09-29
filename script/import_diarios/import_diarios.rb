# Importa frequência e conteúdo dos diários exportados em xlsx (já convertidos
# para diarios.json pelo script Python extract_diarios.py).
#
# Uso:
#   # dry-run (não grava nada, só mostra o que faria):
#   bundle exec rails runner script/import_diarios/import_diarios.rb /tmp/diarios.json iconha
#
#   # grava direto neste banco:
#   bundle exec rails runner script/import_diarios/import_diarios.rb /tmp/diarios.json iconha --commit
#
#   # gera um .sql com os INSERTs reais (capturados do próprio ActiveRecord),
#   # SEM gravar nada neste banco — pra mandar pro time de desenvolvimento
#   # rodar em outro ambiente:
#   bundle exec rails runner script/import_diarios/import_diarios.rb /tmp/diarios.json iconha --sql=/tmp/import_diarios.sql
#
# Idempotente: pode rodar de novo com --commit que não duplica frequência
# nem conteúdo já importados (usa find_or_initialize_by nas chaves naturais).
# O modo --sql roda a MESMA lógica de resolução/gravação, só que dentro de uma
# transação que sempre é desfeita (ROLLBACK) no final — o arquivo .sql gerado
# é exatamente o que o Rails executaria, só que outro banco vai rodar de
# verdade, não este.
#
# O .sql gerado usa \gset (psql) pra ids de linhas novas (contents,
# content_records, daily_frequencies) em vez de valor fixo — o id que o
# Postgres deu AQUI não existe necessariamente no banco de destino (sequence
# em posição diferente), então o valor é capturado em tempo real lá. Por isso
# só roda com `psql -f arquivo.sql`, não copiando/colando num client qualquer.
# Registros de auditoria (tabela audits) não são gerados — não são essenciais
# pro import e complicariam esse encadeamento de ids.

require 'json'

json_path = ARGV[0]
entity_name = ARGV[1]
commit = ARGV.include?('--commit')
sql_output_path = ARGV.find { |a| a.start_with?('--sql=') }&.split('=', 2)&.last
generate_sql = sql_output_path.present?
write_mode = commit || generate_sql

raise "Uso: rails runner import_diarios.rb <diarios.json> <entity_name> [--commit] [--sql=arquivo.sql]" if json_path.blank? || entity_name.blank?
raise "Não use --commit e --sql juntos" if commit && generate_sql

diarios = JSON.parse(File.read(json_path))

STOPWORDS = %w[e de da do das dos].freeze

def normalize(text)
  return '' if text.blank?

  t = I18n.transliterate(text.to_s).downcase
  t = t.gsub(/\(principal\)/, ' ') # sufixo do exportador, não faz parte do nome real
  t = t.gsub(/[^a-z0-9]+/, ' ')
  t.split(' ').reject { |w| STOPWORDS.include?(w) }.join(' ').strip
end

# Turmas que existem na planilha com um nome, mas no sistema estão cadastradas
# de forma combinada (ex.: uma única turma de AEE vespertino atende várias
# séries). Chave e valor já passam por normalize() antes de comparar.
CLASSROOM_ALIASES = {
  normalize('AEE Vespertino Pre I') => 'AEE VESPERTINO I',
  normalize('AEE Vespertino Pre II') => 'AEE VESPERTINO I',
  normalize('AEE Vespertino 4º') => 'AEE VESPERTINO I',
  normalize('AEE Vespertino 5º') => 'AEE VESPERTINO I',
}.freeze

def parse_br_date(str)
  return nil if str.blank?

  Date.strptime(str.to_s, '%d/%m/%Y')
rescue ArgumentError
  nil
end

class ImportStats
  attr_accessor :diarios_ok, :diarios_skipped, :frequencies_created, :frequencies_updated,
                :content_records_created, :content_records_skipped, :students_not_found

  def initialize
    @diarios_ok = 0
    @diarios_skipped = 0
    @frequencies_created = 0
    @frequencies_updated = 0
    @content_records_created = 0
    @content_records_skipped = 0
    @students_not_found = []
  end
end

stats = ImportStats.new

entity = Entity.find_by(name: entity_name)
raise "Entity '#{entity_name}' não encontrada" if entity.blank?

# Tabelas cujo id gerado (serial) é referenciado por OUTRO insert dentro do
# mesmo lote (ex.: content_records_contents.content_id -> contents.id). Um SQL
# com o id LITERAL travado (o valor que o Postgres deu AQUI, neste banco de
# teste) quebra ou aponta pra linha errada assim que rodar em outro banco com
# a sequence em outra posição (produção, por exemplo). Por isso essas linhas
# usam `RETURNING "id" \gset` do psql em vez de valor fixo — o id de verdade é
# obtido em tempo de execução, no banco de destino.
TRACKED_TABLES = %w[contents content_records daily_frequencies].freeze
FK_TABLE_BY_COLUMN = {
  'content_id' => 'contents',
  'content_record_id' => 'content_records',
  'daily_frequency_id' => 'daily_frequencies',
}.freeze

captured_statements = [] # { sql:, binds: } em ordem de execução, sem inline ainda
id_registrations = []    # { table:, id: } — um por linha nova criada em TRACKED_TABLES,
                         # registrado no Ruby logo após o save (id real, sem parsear SQL)

def register_id(id_registrations, generate_sql, table, id)
  id_registrations << { table: table, id: id } if generate_sql
end

# O ActiveRecord loga o SQL com placeholders ($1, $2...) e os valores reais
# ficam separados em `binds` — precisamos embutir os valores pra virar um .sql
# que roda sozinho em outro banco, sem depender do Rails. Quando o valor é o id
# de uma linha rastreada em TRACKED_TABLES, usamos a variável do psql (:vN_id)
# em vez do literal, pra funcionar em qualquer banco de destino.
def inline_binds(sql, binds, connection, id_var_map = {})
  return sql if binds.blank?

  sql.gsub(/\$(\d+)/) do
    bind = binds[Regexp.last_match(1).to_i - 1]
    value = bind.respond_to?(:value_for_database) ? bind.value_for_database : bind
    column = bind.respond_to?(:name) ? bind.name.to_s : nil
    ref_table = FK_TABLE_BY_COLUMN[column]
    varname = ref_table && value ? id_var_map[[ref_table, value]] : nil

    if varname
      ":#{varname}_id"
    elsif value.nil?
      'NULL'
    else
      connection.quote(value)
    end
  end
end

sql_subscriber = if generate_sql
  ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
    next if payload[:cached]
    sql = payload[:sql].to_s.strip
    next unless sql =~ /\A(INSERT|UPDATE)\b/i
    next if payload[:name] == 'SCHEMA'
    next if sql =~ /\AINSERT INTO "audits"/ # trilha de auditoria: não essencial pro import, e complicaria o encadeamento de ids

    captured_statements << { sql: sql, binds: payload[:binds] }
  end
end

entity.using_connection do
  puts "=" * 100
  mode_label = if generate_sql
                 "MODO: GERAR SQL (nada será gravado aqui, vai virar #{sql_output_path})"
               elsif commit
                 "MODO: COMMIT (vai gravar no banco)"
               else
                 "MODO: DRY-RUN (nada será gravado)"
               end
  puts mode_label
  puts "=" * 100

  sql_transaction_wrapper = lambda do |&block|
    if generate_sql
      ActiveRecord::Base.transaction(requires_new: true) do
        block.call
        raise ActiveRecord::Rollback
      end
    else
      block.call
    end
  end

  sql_transaction_wrapper.call do
  diarios.each do |diario|
    puts "\n--- #{diario['file']} ---"

    begin
    ActiveRecord::Base.transaction(requires_new: true) do
    unity = Unity.where('unaccent(name) ILIKE unaccent(?)', diario['escola'].to_s).first
    unless unity
      puts "  [PULADO] Escola não encontrada: #{diario['escola'].inspect}"
      stats.diarios_skipped += 1
      next
    end

    year = parse_br_date(diario['data_inicio'])&.year
    unless year
      puts "  [PULADO] Não consegui extrair o ano letivo de 'Data de início': #{diario['data_inicio'].inspect}"
      stats.diarios_skipped += 1
      next
    end

    classroom_name = CLASSROOM_ALIASES[normalize(diario['turma'])] || diario['turma'].to_s

    classroom = Classroom.where(unity_id: unity.id, year: year)
                         .where('unaccent(description) ILIKE unaccent(?)', classroom_name)
                         .first

    unless classroom
      candidates = Classroom.where(unity_id: unity.id, year: year).pluck(:description)
      puts "  [PULADO] Turma '#{diario['turma']}' não encontrada em #{unity.name}/#{year}."
      puts "           Turmas existentes: #{candidates.join(', ')}"
      stats.diarios_skipped += 1
      next
    end

    if classroom_name != diario['turma'].to_s
      puts "  [INFO] Turma '#{diario['turma']}' mapeada por alias para '#{classroom.description}'."
    end

    diario_end_date = parse_br_date(diario['data_termino']) || Date.current

    # unscoped: inclui vínculos já descartados (discarded_at), desde que
    # estivessem ativos durante o período letivo da planilha — a escola pode
    # ter reestruturado os componentes curriculares depois (ex.: trocou
    # "Campos de Experiência (Principal)" pelos componentes novos por campo).
    teacher_discipline_classrooms = TeacherDisciplineClassroom.unscoped
                                                               .where(classroom_id: classroom.id, active: true)
                                                               .where('discarded_at IS NULL OR discarded_at > ?', diario_end_date)
                                                               .includes(:teacher, :discipline)

    teacher_link = teacher_discipline_classrooms.find do |tdc|
      normalize(tdc.teacher.name).include?(normalize(diario['professor'])) ||
        normalize(diario['professor']).include?(normalize(tdc.teacher.name))
    end

    unless teacher_link
      candidates = teacher_discipline_classrooms.map { |tdc| tdc.teacher.name }.uniq
      puts "  [PULADO] Professor(a) '#{diario['professor']}' não está vinculado(a) à turma '#{classroom.description}'."
      puts "           Professores vinculados a essa turma: #{candidates.join(', ')}"
      stats.diarios_skipped += 1
      next
    end

    teacher = teacher_link.teacher

    teacher_disciplines = teacher_discipline_classrooms.select { |tdc| tdc.teacher_id == teacher.id }

    discipline_link = teacher_disciplines.find do |tdc|
      normalize(tdc.discipline.description) == normalize(diario['disciplina'])
    end

    # Fallback: o nome do componente na planilha não bate com nada, mas esse
    # professor só tem UM componente vinculado a essa turma — não tem outra
    # opção possível, então é seguro assumir que é esse (o nome pode ter
    # mudado desde a exportação, ex. "Atividades Extra Curriculares" virou
    # "Atividades Pedagógicas").
    if discipline_link.blank? && teacher_disciplines.size == 1
      discipline_link = teacher_disciplines.first
      puts "  [INFO] Componente '#{diario['disciplina']}' não bate com o nome cadastrado, mas " \
           "#{teacher.name} só tem um componente nessa turma ('#{discipline_link.discipline.description}') — usando ele."
    end

    # Fallback: planilhas "(Principal)" de Educação Infantil (Campos de
    # Experiência) — o exportador junta vários componentes numa área de
    # conhecimento só. Se o professor tiver exatamente UM componente ligado a
    # uma área de conhecimento cujo nome contenha as mesmas palavras-chave, é
    # esse.
    if discipline_link.blank? && diario['disciplina'].to_s =~ /\(principal\)/i
      keywords = normalize(diario['disciplina']).split(' ').reject { |w| w.length < 4 }

      principal_candidates = teacher_disciplines.select do |tdc|
        ka_name = normalize(tdc.discipline.knowledge_area&.description.to_s)
        ka_name.include?('principal') && keywords.any? { |kw| ka_name.include?(kw) }
      end

      if principal_candidates.size == 1
        discipline_link = principal_candidates.first
        puts "  [INFO] Componente '#{diario['disciplina']}' resolvido pela área de conhecimento " \
             "'#{discipline_link.discipline.knowledge_area.description}' -> componente '#{discipline_link.discipline.description}'."
      end
    end

    unless discipline_link
      candidates = teacher_discipline_classrooms.select { |tdc| tdc.teacher_id == teacher.id }
                                                 .map { |tdc| tdc.discipline.description }.uniq
      puts "  [PULADO] Componente '#{diario['disciplina']}' não está vinculado a #{teacher.name} nessa turma."
      puts "           Componentes vinculados: #{candidates.join(', ')}"
      stats.diarios_skipped += 1
      next
    end

    discipline = discipline_link.discipline

    # Vínculo já descartado hoje (mas válido na época da planilha): frequência
    # não tem esse tipo de validação, mas ContentRecord/DisciplineContentRecord
    # exigem que o professor esteja ATUALMENTE vinculado ao componente — então
    # dá pra importar a frequência, mas não o conteúdo, sem contornar a
    # validação na marra.
    skip_content = discipline_link.discarded_at.present?
    if skip_content
      puts "  [ATENÇÃO] Vínculo professor-componente foi desativado em #{discipline_link.discarded_at.to_date} " \
           "— frequência será importada, mas conteúdo NÃO (o sistema exige vínculo ativo hoje pra criar conteúdo)."
    end

    frequency_type_definer = FrequencyTypeDefiner.new(classroom, teacher.id, year: year)
    frequency_type_definer.define!
    frequency_type = frequency_type_definer.frequency_type

    school_calendar = CurrentSchoolCalendarFetcher.new(unity, classroom, year).fetch
    unless school_calendar
      puts "  [PULADO] Não encontrei calendário letivo para #{unity.name}/#{classroom.description}/#{year}."
      stats.diarios_skipped += 1
      next
    end

    puts "  OK: escola=#{unity.name} turma=#{classroom.description} professor=#{teacher.name} " \
         "disciplina=#{discipline.description} tipo_frequencia=#{frequency_type}"
    stats.diarios_ok += 1

    # -------------------- Alunos matriculados na turma --------------------
    enrolled_students = StudentEnrollmentClassroom.by_classroom(classroom.id)
                                                   .includes(student_enrollment: :student)
                                                   .map(&:student_enrollment)
                                                   .compact

    students_by_name = {}
    students_by_birthdate = Hash.new { |h, k| h[k] = [] }
    enrolled_students.each do |enrollment|
      next if enrollment.student.blank?

      students_by_name[normalize(enrollment.student.name)] ||= enrollment.student
      students_by_birthdate[enrollment.student.birth_date] << enrollment.student if enrollment.student.birth_date
    end

    # -------------------- Frequência --------------------
    frequencies_by_date = Hash.new { |h, k| h[k] = {} }

    diario['students'].each do |row|
      student = students_by_name[normalize(row['name'])]

      if student.blank?
        birthdate = parse_br_date(row['birthdate'])
        same_birthdate = birthdate ? students_by_birthdate[birthdate].uniq : []

        if same_birthdate.size == 1
          student = same_birthdate.first
          puts "  [ATENÇÃO] Aluno casado só pela data de nascimento: planilha='#{row['name']}' <=> sistema='#{student.name}' (nasc. #{birthdate})"
        elsif same_birthdate.size > 1
          # Mesma data de nascimento pra mais de um aluno (ex.: gêmeos) — só
          # aceita se o primeiro nome (prenome) também bater, senão fica
          # ambíguo de verdade e não arrisca.
          first_name = normalize(row['name']).split(' ').first
          by_first_name = same_birthdate.select { |s| normalize(s.name).split(' ').first == first_name }

          if by_first_name.size == 1
            student = by_first_name.first
            puts "  [ATENÇÃO] Aluno casado por data de nascimento + primeiro nome (havia mais de um com a mesma data): " \
                 "planilha='#{row['name']}' <=> sistema='#{student.name}' (nasc. #{birthdate})"
          end
        end
      end

      unless student
        stats.students_not_found << { file: diario['file'], name: row['name'] }
        next
      end

      row['marks'].each do |date_str, mark|
        next if mark == '—' # não matriculado(a) ainda / dispensado(a) nesse dia

        date = parse_br_date(date_str)
        next if date.blank?

        frequencies_by_date[date][student.id] = (mark == '•')
      end
    end

    frequencies_by_date.each do |date, presence_by_student_id|
      next unless school_calendar.school_day?(date, classroom.classrooms_grades.first&.grade_id, classroom.id, discipline.id)

      if write_mode
        daily_frequency = DailyFrequency.find_or_initialize_by(
          unity_id: unity.id,
          classroom_id: classroom.id,
          frequency_date: date,
          discipline_id: frequency_type == FrequencyTypes::GENERAL ? nil : discipline.id,
          class_number: frequency_type == FrequencyTypes::GENERAL ? nil : 1,
          period: classroom.period.to_i
        )
        is_new_frequency = daily_frequency.new_record?
        daily_frequency.school_calendar_id = school_calendar.id
        daily_frequency.owner_teacher_id = daily_frequency.teacher_id = teacher.id
        daily_frequency.origin = OriginTypes::WEB
        daily_frequency.save!
        register_id(id_registrations, generate_sql, 'daily_frequencies', daily_frequency.id) if is_new_frequency

        presence_by_student_id.each do |student_id, present|
          dfs = daily_frequency.build_or_find_by_student(student_id)
          dfs.present = present
          dfs.save! if dfs.changed?
        end

        if is_new_frequency
          stats.frequencies_created += 1
        else
          stats.frequencies_updated += 1
        end
      else
        exists = DailyFrequency.exists?(
          unity_id: unity.id,
          classroom_id: classroom.id,
          frequency_date: date,
          discipline_id: frequency_type == FrequencyTypes::GENERAL ? nil : discipline.id
        )
        exists ? (stats.frequencies_updated += 1) : (stats.frequencies_created += 1)
      end
    end

    # -------------------- Conteúdo --------------------
    diario['contents'].each do |content_row|
      next if skip_content

      date = parse_br_date(content_row['date'])
      next if date.blank?
      next unless school_calendar.school_day?(date, classroom.classrooms_grades.first&.grade_id, classroom.id, discipline.id)

      already_exists = DisciplineContentRecord.by_teacher_id(teacher.id)
                                              .by_classroom_id(classroom.id)
                                              .by_discipline_id(discipline.id)
                                              .by_date(date)
                                              .exists?

      if already_exists
        stats.content_records_skipped += 1
        next
      end

      if write_mode
        content_existed_before = Content.exists?(description: content_row['content'])
        content = Content.find_or_create_by_description!(content_row['content'])
        register_id(id_registrations, generate_sql, 'contents', content.id) unless content_existed_before

        # Mesma ordem de construção usada por DisciplineContentRecordsController#create:
        # monta a partir do DisciplineContentRecord (não do ContentRecord), e seta
        # teacher_id nos dois — construir na ordem inversa (ContentRecord -> build_*)
        # dispara um bug de contexto de validação do Rails 5 em associações
        # aninhadas (ColumnsLockable#can_update? roda fora do :update, current_user nil).
        discipline_content_record = DisciplineContentRecord.new(discipline: discipline)
        discipline_content_record.build_content_record(
          unity_id: unity.id,
          classroom: classroom,
          record_date: date,
          origin: OriginTypes::WEB
        )
        discipline_content_record.content_record.teacher = teacher
        discipline_content_record.content_record.content_ids = [content.id]
        discipline_content_record.content_record.creator_type = 'discipline_content_record'
        discipline_content_record.teacher_id = teacher.id
        discipline_content_record.save!
        register_id(id_registrations, generate_sql, 'content_records', discipline_content_record.content_record.id)
      end

      stats.content_records_created += 1
    end
    end # transaction
    rescue => e
      puts "  [ERRO] #{e.class}: #{e.message}"
      puts "         #{e.backtrace.first(5).join("\n         ")}" if ENV['DEBUG']
      stats.diarios_skipped += 1
    end
  end
  end # sql_transaction_wrapper
end

ActiveSupport::Notifications.unsubscribe(sql_subscriber) if sql_subscriber

if generate_sql
  # Passo 1: correlaciona, na ordem de execução, cada INSERT capturado numa
  # TRACKED_TABLE com o id real que o Ruby já tinha (id_registrations) — dá o
  # nome de variável psql (vN) que vai receber esse id no banco de destino.
  id_var_map = {} # [table, id_real_neste_banco] => "vN"
  registrations_by_table = Hash.new { |h, k| h[k] = [] }
  id_registrations.each { |r| registrations_by_table[r[:table]] << r[:id] }
  next_registration_index = Hash.new(0)
  var_counter = 0
  gset_var_by_index = {}

  captured_statements.each_with_index do |stmt, idx|
    table = stmt[:sql][/\AINSERT INTO "(\w+)"/, 1]
    next unless TRACKED_TABLES.include?(table)
    next unless stmt[:sql] =~ /RETURNING "id"\z/

    real_id = registrations_by_table[table][next_registration_index[table]]
    next if real_id.nil? # não deveria acontecer, mas não trava a geração do SQL por causa disso

    next_registration_index[table] += 1
    var_counter += 1
    varname = "v#{var_counter}"
    id_var_map[[table, real_id]] = varname
    gset_var_by_index[idx] = varname
  end

  # Passo 2: embute os valores (usando id_var_map pra trocar ids de linhas
  # novas por variáveis :vN_id) e escreve o arquivo final.
  connection = ActiveRecord::Base.connection
  File.open(sql_output_path, 'w') do |f|
    f.puts "-- Gerado por script/import_diarios/import_diarios.rb em #{Time.current}"
    f.puts "-- Entity: #{entity_name} | Fonte: #{json_path}"
    f.puts "-- Ids de linhas criadas neste lote (contents/content_records/daily_frequencies) são"
    f.puts "-- capturados em tempo de execução via \\gset — não são valores fixos deste banco de"
    f.puts "-- teste, então o arquivo é seguro pra rodar em outro banco (ex.: produção)."
    f.puts "-- Rodar com: psql <conexao> -v ON_ERROR_STOP=1 -f este_arquivo.sql"
    f.puts "BEGIN;"
    f.puts
    captured_statements.each_with_index do |stmt, idx|
      inlined = inline_binds(stmt[:sql], stmt[:binds], connection, id_var_map)

      if gset_var_by_index[idx]
        f.puts "#{inlined} \\gset #{gset_var_by_index[idx]}_"
      else
        f.puts "#{inlined};"
      end
    end
    f.puts
    f.puts "COMMIT;"
  end
end

puts "\n" + ("=" * 100)
puts "RESUMO"
puts "=" * 100
puts "Diários resolvidos com sucesso: #{stats.diarios_ok}"
puts "Diários pulados (veja motivos acima): #{stats.diarios_skipped}"
puts "Frequências #{write_mode ? 'criadas' : 'a criar'}: #{stats.frequencies_created}"
puts "Frequências #{write_mode ? 'atualizadas' : 'a atualizar'}: #{stats.frequencies_updated}"
puts "Registros de conteúdo #{write_mode ? 'criados' : 'a criar'}: #{stats.content_records_created}"
puts "Registros de conteúdo já existentes (pulados): #{stats.content_records_skipped}"

if stats.students_not_found.any?
  puts "\nAlunos NÃO encontrados na turma (conferir nome/matrícula):"
  stats.students_not_found.uniq.each do |s|
    puts "  - #{s[:name]} (#{s[:file]})"
  end
end

if generate_sql
  puts "\nSQL gerado em #{sql_output_path} (#{captured_statements.size} comandos). Nada foi gravado neste banco."
elsif commit
  puts "\nImportação concluída."
else
  puts "\nDry-run concluído. Rode de novo com --commit para gravar aqui, ou --sql=arquivo.sql para gerar o SQL."
end
