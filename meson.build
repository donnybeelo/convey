project('convey', [ 'vala', 'c' ],
  version: '46.0',
  license: 'LGPL-2.1-or-later',
  meson_version: '>= 1.7',
)

# Determine the type of build
profile = get_option('profile')
appid_suffix = ''
name_suffix = ''
if profile == 'auto'
  if run_command('[', '-d', '.git', ']', check: false).returncode() == 0
    profile = 'development'
  else
    error('No build profile specified, see BUILDING.md')
  endif
endif

if profile == 'development'
  appid_suffix = '.Devel'
elif profile == 'beta'
  appid_suffix = '.Beta'
  name_suffix = ' (Beta)'
elif profile != 'release'
  error('Unknown build profile specified, see BUILDING.md')
endif

# Configurable install dirs
convey_prefix = get_option('prefix')
bin_dir = convey_prefix / get_option('bindir')
data_dir = convey_prefix / get_option('datadir')
lib_dir = convey_prefix / get_option('libdir')
locale_dir = convey_prefix / get_option('localedir')

# Not every platform has every library the client uses. Each flag below
# gates both the dependency and a --define of the same name in upper case,
# so the code can do without it. See src/client/meson.build.
#
# WebKitGTK has no Windows port: Components.NativeWebView is backed by
# WebView2 there instead, and the WebKit web process extension is not
# built at all, its work being done by injected JavaScript.
have_webkit = host_machine.system() != 'windows'
have_goa = host_machine.system() != 'windows'
have_folks = host_machine.system() != 'windows'
have_gsound = host_machine.system() != 'windows'
have_gcr = host_machine.system() != 'windows'
# Yelp user documentation needs itstool, which is not packaged for Windows.
have_yelp = host_machine.system() != 'windows'
# A few POSIX functions have no Windows equivalent in the C library.
have_posix = host_machine.system() != 'windows'
# libsecret needs a Secret Service; Windows uses the Credential Manager.
have_libsecret = host_machine.system() != 'windows'

# Source dirs
metadata_dir = meson.project_source_root() / 'bindings'/ 'metadata'
po_dir = meson.project_source_root() / 'po'
vapi_dir = meson.project_source_root() / 'bindings' / 'vapi'

# Compiler configuration
add_project_arguments([
    # Make sure Meson can find custom VAPIs
    '--vapidir', vapi_dir,
    '--metadatadir', metadata_dir,
  ],
  language: 'vala'
)
cc = meson.get_compiler('c')
valac = meson.get_compiler('vala')

#
# Required libraries and other dependencies
#

target_glib = '2.80'
target_gtk = '4.16.0'
target_vala = '0.56'
target_webkit = '2.40'

if not valac.version().version_compare('>=' + target_vala)
  error('Vala does not meet minimum required version: ' + target_vala)
endif

if host_machine.system() == 'windows'
  # Only the WebView2 headers are needed to build: the loader is opened
  # at run time, so that a machine without the Edge WebView2 Runtime
  # installed still starts, and says so in place of each message body.
  if not cc.has_header('WebView2.h')
    error(
      'WebView2.h not found. Install the webview2-loader package, ' +
      'e.g. pacman -S mingw-w64-ucrt-x86_64-webview2-loader'
    )
  endif
endif

# Primary deps
glib = dependency('glib-2.0', version: '>=' + target_glib)
gmime = dependency('gmime-3.0', version: '>= 3.2.4')
sqlite = dependency('sqlite3', version: '>= 3.24')

# Secondary deps - keep sorted alphabetically
gee = dependency('gee-0.8', version: '>= 0.8.5')
gio = dependency('gio-2.0', version: '>=' + target_glib)
gthread = dependency('gthread-2.0', version: '>=' + target_glib)
icu_uc = dependency('icu-uc', version: '>=60')
json_glib = dependency('json-glib-1.0', version: '>= 1.0')
libmath = cc.find_library('m')
libsoup = dependency('libsoup-3.0')
libstemmer_dep = cc.find_library('stemmer')
libunwind_dep = dependency(
  'libunwind', version: '>= 1.1', required: get_option('libunwind')
)
libunwind_generic_dep = dependency(
  'libunwind-generic', version: '>= 1.1', required: get_option('libunwind')
)
libxml = dependency('libxml-2.0', version: '>= 2.7.8')
libytnef = dependency('libytnef', version: '>= 1.9.3', required: get_option('tnef'))
posix = valac.find_library('posix')

# Client deps
gtk = dependency('gtk4', version: '>=' + target_gtk)
cairo = dependency('cairo')
enchant = dependency('enchant-2', version: '>=2.1')
iso_codes = dependency('iso-codes')
libadwaita = dependency('libadwaita-1', version: '>= 1.7')
libpeas = dependency('libpeas-2')
libspelling = dependency('libspelling-1')

# Client deps that are not available everywhere
if have_webkit
  webkitgtk = dependency('webkitgtk-6.0', version: '>=' + target_webkit)
  javascriptcoregtk = dependency(
    'javascriptcoregtk-6.0', version: '>=' + target_webkit
  )
  webkitgtk_web_extension = dependency(
    'webkitgtk-web-process-extension-6.0', version: '>=' + target_webkit
  )
endif
if have_goa
  goa = dependency('goa-1.0')
endif
if have_folks
  folks = dependency('folks', version: '>=0.11')
endif
if have_gsound
  gsound = dependency('gsound')
endif
if have_gcr
  gck = dependency('gck-2')
  gcr = dependency('gcr-4')
endif
if have_libsecret
  libsecret = dependency('libsecret-1', version: '>= 0.11')
endif

# System dependencies above ensures appropriate versions for the
# following libraries, but the declared dependency is what we actually
# build against so we can include the custom VAPI correctly.

icu_uc = declare_dependency(
  dependencies: [
    valac.find_library('icu-uc', dirs: [vapi_dir]),
    cc.find_library('icuuc'),
  ],
)

if libunwind_dep.found()
  # We need to add native lib to the search path for these so Flatpak
  # builds can find it.
  unwind_lib = libunwind_dep.get_variable(pkgconfig: 'libdir')
  libunwind = declare_dependency(
     dependencies: [
       valac.find_library('libunwind', dirs: [vapi_dir, unwind_lib]),
       cc.find_library('libunwind', dirs: unwind_lib),
       cc.find_library('libunwind-generic', dirs: unwind_lib)
     ],
   )
endif

libstemmer = declare_dependency(
  dependencies: [
    valac.find_library('libstemmer', dirs: [vapi_dir]),
    libstemmer_dep,
  ],
)

# Optional dependencies
appstreamcli = find_program('appstreamcli', required: false)
desktop_file_validate = find_program('desktop-file-validate', required: false)
libmessagingmenu_dep = dependency('messaging-menu', version: '>= 12.10', required: false)

#
# Internal build configuration
#

# Build variables
convey_id = 'net.donnybeelo.Convey@0@'.format(appid_suffix)
convey_version = meson.project_version()
revno = get_option('revno')
if revno == ''
  revno = run_command('build-aux/git_version.py', check: false).stdout().strip()
endif

gnome = import('gnome')
i18n = import('i18n')

# Static install dirs
dbus_services_dir = data_dir / 'dbus-1' / 'services'
client_lib_dir = lib_dir / 'convey'
plugins_dir = client_lib_dir / 'plugins'
web_extensions_dir = client_lib_dir / 'web-extensions'

# Ensure SQLite was built correctly
if not cc.has_header_symbol('sqlite3.h', 'SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER', dependencies: sqlite)
  error('SQLite3 was not built with FTS3 support. See BUILDING.md for details.')
endif
if not cc.has_header_symbol('sqlite3.h', 'Fts5ExtensionApi', dependencies: sqlite)
  error('SQLite3 was not built with FTS5 support. See BUILDING.md for details.')
endif

#
# Build glue
#

valadoc = find_program('valadoc', required: get_option('valadoc'))

vala_unit_proj = subproject(
  'vala-unit',
  default_options: [
    'install=false',
    'valadoc=@0@'.format(valadoc.found())
  ]
)
vala_unit_dep = vala_unit_proj.get_variable('vala_unit_dep')

# Language detection

iso_codes_dir = iso_codes.get_variable(pkgconfig: 'prefix')/'share'/'xml'/'iso-codes'

iso_639_xml = get_option('iso_639_xml')
if iso_639_xml == ''
  iso_639_xml = iso_codes_dir / 'iso_639.xml'
endif

iso_3166_xml = get_option('iso_3166_xml')
if iso_3166_xml == ''
  iso_3166_xml = iso_codes_dir / 'iso_3166.xml'
endif

files(iso_639_xml, iso_3166_xml) # Check to make sure these exist

# Make sure the locale C.UTF-8 is installed on the system. There is no
# `locale` binary on Windows, hence the guard.
if host_machine.system() != 'windows'
  c_utf8_check = run_command('locale', '-a', check: true).stdout()
  if not ('C.utf8' in c_utf8_check.split('\n'))
    warning('C.utf8 locale not available on this system.')
  endif
endif

# Post-install script
gnome.post_install(
  gtk_update_icon_cache: true,
  glib_compile_schemas: true,
  update_desktop_database: true,
)

# Subfolders
subdir('desktop')
if have_yelp
  subdir('help')
endif
subdir('icons')
subdir('po')
subdir('sql')
subdir('ui')
subdir('src')
subdir('test')
