#
# Builds individual plugins. The client's plugin classes themselves
# are built back up the tree.
#

plugin_dependencies = [
  config_dep,
  client_dep,
  engine_dep,
  gee,
  gmime,
  gtk,
  libadwaita,
  libmath,
  libpeas,
]
if have_webkit
  plugin_dependencies += [ javascriptcoregtk, webkitgtk ]
endif
if have_goa
  plugin_dependencies += goa
endif
if have_folks
  plugin_dependencies += folks
endif

plugin_c_args = convey_c_args

# Use .desktop.in since xgettext doesn't recognise .plugin files as
# desktop files when translating them at install time.
plugin_data_src_suffix = '.desktop.in'
plugin_data_suffix = '.plugin'

# LibPeas plugins are not using a valid .desktop keyword
# Force msgfmt to translate Description
msgfmt_plugin_cmd = [
  find_program('msgfmt'),
  '--desktop',
  '--keyword=Name',
  '--keyword=Description',
  '-d', po_dir,
  '--template=@INPUT@',
  '--output=@OUTPUT@'
]

subdir('desktop-notifications')
subdir('email-templates')
subdir('folder-highlight')
subdir('mail-merge')
subdir('messaging-menu')
subdir('notification-badge')
if have_gsound
  subdir('sent-sound')
endif
subdir('special-folders')
