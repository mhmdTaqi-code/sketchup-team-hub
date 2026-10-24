# SketchUp Team Hub â€” shared-project collaboration for a SketchUp team.
# Loader: registers the extension; the code lives in su_team_hub/.

require 'sketchup.rb'
require 'extensions.rb'

module TeamHub
  PLUGIN_ID = 'su_team_hub'.freeze
  PLUGIN_VERSION = '2.1.4'.freeze

  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new('Team Hub', File.join(PLUGIN_ID, 'main'))
    ext.description = 'Work on one shared SketchUp project as a team: ' \
                      'reservations, live sync, history. Connects to a Team Hub server.'
    ext.version = PLUGIN_VERSION
    ext.creator = 'Team Hub'
    ext.copyright = '2026'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
