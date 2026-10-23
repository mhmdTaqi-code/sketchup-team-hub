# The Team Hub panel (HtmlDialog). Ruby pushes a state snapshot into it;
# the page calls back with actions.

require 'json'

module TeamHub
  class Panel
    def initialize
      @dialog = nil
      @refresh_timer = nil
    end

    def build
      d = UI::HtmlDialog.new(
        dialog_title: 'Team Hub',
        preferences_key: 'TeamHub.Panel',
        width: 400, height: 760, min_width: 330, min_height: 420,
        resizable: true, scrollable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      d.set_file(File.join(TeamHub::DIR, 'ui', 'panel.html'))
      d.add_action_callback('th') do |_ctx, action, json|
        payload = begin
          json.to_s.empty? ? {} : JSON.parse(json.to_s)
        rescue JSON::ParserError
          {}
        end
        TeamHub.handle_ui(action.to_s, payload)
      end
      d.set_on_closed { @dialog = nil }
      d
    end

    def show
      @dialog ||= build
      @dialog.visible? ? @dialog.bring_to_front : @dialog.show
      refresh
    end

    def visible?
      @dialog&.visible? ? true : false
    end

    # Coalesce bursts of changes into one render.
    def refresh
      return unless visible?
      return if @refresh_timer
      @refresh_timer = UI.start_timer(0.25, false) do
        @refresh_timer = nil
        render
      end
    end

    def render
      return unless visible?
      @dialog.execute_script("TH.render(#{js(TeamHub.ui_state)})")
    rescue StandardError => e
      TeamHub.log_error(e)
    end

    def toast(text)
      return unless visible?
      @dialog.execute_script("TH.toast(#{js(text.to_s)})")
    end

    private

    def js(value)
      JSON.generate(value).gsub(" ", ' ').gsub(" ", ' ')
    end
  end
end
