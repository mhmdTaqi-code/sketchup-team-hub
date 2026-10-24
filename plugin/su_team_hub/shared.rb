# The shared file: instead of rebuilding a project object by object, the owner
# uploads the whole .skp once and teammates download that one file and start
# from it. Every object in it carries its id and revision, so afterwards only
# the objects that change travel.

require 'json'
require 'fileutils'
require 'securerandom'

module TeamHub
  CHUNK = 2 * 1024 * 1024

  class << self
    attr_reader :busy_text

    def set_busy(kind, text)
      @busy = kind
      @busy_text = text
      Sketchup.status_text = "Team Hub: #{text}"
      panel_refresh
    end

    def clear_busy
      @busy = nil
      @busy_text = nil
      panel_refresh
    end

    def fail_busy(text)
      clear_busy
      flash(text)
    end

    # ------------------------------------------------------------ share (owner)

    def share_file
      return flash('سجل دخول أول') unless logged_in?
      return flash('حسابك مشاهدة فقط') if me && me['role'] == 'viewer'
      model = Sketchup.active_model
      if model.path.to_s.empty?
        UI.messagebox('احفظ الملف أول (File ← Save)، وبعدين دوس «مشاركة هذا الملف».')
        return
      end
      binding = model_binding(model)
      project = binding && (@projects || []).find { |p| p['id'] == binding['project_id'] }
      if project && project['file'] && me['role'] != 'admin' && project['created_by'] != me['id']
        return flash("ملف «#{project['name']}» يبدله بس المدير أو صاحب المشروع. شغلك يوصل للكل وحده، ما تحتاج تشاركه.")
      end
      return share_into(model, project) if project

      name = File.basename(model.path, '.skp')
      set_busy('share', 'يسوي مشروع جديد…')
      client.request(:post, '/api/projects', { 'name' => name }) do |st, data|
        next fail_busy("ما انشأ المشروع: #{data && data['error']}") unless st == 200
        created = data['project']
        load_projects do
          share_into(model, (@projects || []).find { |p| p['id'] == created['id'] } || created)
        end
      end
    end

    def share_into(model, project)
      stop_session
      set_busy('share', 'يجهز الملف…')
      client.request(:get, "/api/projects/#{project['id']}/state", nil, timeout: 120) do |st, state|
        next fail_busy('ما كدرت أجيب حالة المشروع من السيرفر') unless st == 200 && state
        begin
          prepare_shared_model(model, project, state)
          model.save # my own file keeps the ids, so it stays in sync too
          tmp = File.join(Sketchup.temp_dir, "teamhub_share_#{SecureRandom.hex(4)}.skp")
          model.save_copy(tmp)
          data = File.binread(tmp)
          File.delete(tmp) rescue nil
        rescue StandardError => e
          log_error(e)
          next fail_busy("ما كدرت أجهز الملف: #{e.message}")
        end
        my_locks = (state['locks'] || []).select { |l| l['user_id'] == me['id'] }.map { |l| l['oid'] }
        upload_shared(project, data, File.basename(model.path)) do |ok|
          next unless ok
          go = lambda do
            start_session(model, project, :resume)
            flash("انرفع الملف المشترك (#{(data.bytesize / 1048576.0).round(1)} MB). صديقك يدوس «تحميل الملف المشترك» ويبدي وياك.")
          end
          if my_locks.empty?
            go.call
          else
            # Free editing by default: hand back the reservations an old upload left.
            client.request(:post, "/api/projects/#{project['id']}/unlock", { 'oids' => my_locks }, timeout: 60) { go.call }
          end
        end
      end
    end

    # Ids on every object, server revisions stamped, model bound to the project.
    def prepare_shared_model(model, project, state)
      server = {}
      (state['objects'] || []).each { |o| server[o['oid']] = o }
      locks = {}
      (state['locks'] || []).each { |l| locks[l['oid']] = l['user_id'] }
      seen = {}
      model.start_operation('Team Hub: مشاركة الملف', true)
      model.set_attribute(DICT, 'project_id', project['id'])
      model.set_attribute(DICT, 'project_name', project['name'])
      model.set_attribute(DICT, 'server', client.server)
      model.entities.to_a.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        oid = e.get_attribute(DICT, 'oid')
        if oid.nil? || seen[oid]
          oid = "o#{SecureRandom.hex(10)}"
          e.set_attribute(DICT, 'oid', oid)
        end
        seen[oid] = true
        stamp_rev(e, server[oid])
        e.locked = !locks[oid].nil? && locks[oid] != me['id']
        next unless e.is_a?(Sketchup::ComponentInstance)
        d = e.definition
        did = d.get_attribute(DICT, 'did')
        unless did
          did = SecureRandom.hex(10)
          d.set_attribute(DICT, 'did', did)
        end
        stamp_rev(d, server["d_#{did}"])
      end
      model.commit_operation
    end

    def stamp_rev(holder, server_obj)
      if server_obj && !server_obj['deleted']
        holder.set_attribute(DICT, 'rev', server_obj['rev'])
      else
        holder.delete_attribute(DICT, 'rev')
      end
    end

    def upload_shared(project, data, name, index = 0, upload_id = nil, &done)
      total = [(data.bytesize.to_f / CHUNK).ceil, 1].max
      chunk = data.byteslice(index * CHUNK, CHUNK) || ''
      final = index == total - 1
      set_busy('share', "يرفع الملف المشترك… #{index * 100 / total}%")
      body = {
        'index' => index, 'upload_id' => upload_id, 'data' => [chunk].pack('m0'),
        'final' => final, 'name' => name, 'sketchup' => su_version_label,
      }
      client.request(:post, "/api/projects/#{project['id']}/file/chunk", body, timeout: 300) do |st, res|
        unless st == 200 && res
          msg = res && res['error'] == 'only_owner_can_replace' ? 'ملف هذا المشروع يبدله بس المدير أو صاحب المشروع' : "فشل رفع الملف (#{(res && res['error']) || st})"
          fail_busy(msg)
          next done.call(false)
        end
        if final
          clear_busy
          done.call(true)
        else
          upload_shared(project, data, name, index + 1, res['upload_id'], &done)
        end
      end
    end

    # Admin: take a project off everyone's list (the server keeps the file).
    def delete_project(project_id)
      project = (@projects || []).find { |p| p['id'] == project_id.to_i }
      return flash('المشروع مو موجود') unless project
      stop_session if @session && @session.pid == project['id']
      client.request(:delete, "/api/projects/#{project['id']}") do |st, data|
        if st == 200
          flash("انحذف «#{project['name']}» من قائمة الكل")
        else
          flash("ما انحذف: #{(data && data['error']) || st}")
        end
        load_projects
      end
    end

    # ------------------------------------------------------------ download (teammate)

    def download_shared(project_id)
      project = (@projects || []).find { |p| p['id'] == project_id.to_i }
      return flash('المشروع مو موجود') unless project
      set_busy('download', 'يجيب معلومات الملف…')
      client.request(:get, "/api/projects/#{project['id']}/file") do |st, res|
        unless st == 200 && res
          next fail_busy('ماكو ملف مشترك بهذا المشروع بعد. صاحب المشروع لازم يدوس «مشاركة هذا الملف».')
        end
        info = res['file']
        dir = File.join(ENV['USERPROFILE'] || Dir.home, 'Documents', 'TeamHub')
        FileUtils.mkdir_p(dir)
        base = project['name'].to_s.gsub(/[\\\/:*?"<>|]/, '_')
        path = File.join(dir, "#{base}.skp")
        path = File.join(dir, "#{base}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.skp") if File.exist?(path)
        part = "#{path}.part"
        File.binwrite(part, '')
        fetch_chunk(project['id'], info, part, 0) do |ok|
          next unless ok
          File.rename(part, path)
          clear_busy
          flash('نزل الملف، دا ينفتح…')
          UI.start_timer(0.2, false) { Sketchup.open_file(path) } # opening it connects by itself
        end
      end
    end

    def fetch_chunk(pid, info, part, offset, &done)
      size = [info['size'].to_i, 1].max
      set_busy('download', "ينزّل الملف المشترك… #{offset * 100 / size}%")
      client.request(:get, "/api/projects/#{pid}/file?offset=#{offset}&length=#{info['chunk']}", nil, timeout: 300) do |st, res|
        unless st == 200 && res && res['data']
          fail_busy('انقطع التنزيل، جرّب مرة ثانية')
          next done.call(false)
        end
        bytes = res['data'].unpack1('m0')
        File.open(part, 'ab') { |f| f.write(bytes) }
        nxt = offset + bytes.bytesize
        if bytes.empty? || nxt >= info['size'].to_i
          done.call(true)
        else
          fetch_chunk(pid, info, part, nxt, &done)
        end
      end
    end
  end
end
