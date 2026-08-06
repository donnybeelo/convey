# Convey client

client_package_name = 'convey-client'
client_api_version = '.'.join([
  convey_version.split('.')[0],
  convey_version.split('.')[1]
])
client_package = '@0@-@1@'.format(
  client_package_name,
  client_api_version
)

client_vala_sources = files(
  'application/application-account-context.vala',
  'application/application-account-interface.vala',
  'application/application-attachment-manager.vala',
  'application/application-certificate-manager.vala',
  'application/application-client.vala',
  'application/application-command.vala',
  'application/application-configuration.vala',
  'application/application-contact-store.vala',
  'application/application-contact.vala',
  'application/application-controller.vala',
  'application/application-database-manager.vala',
  'application/application-email-plugin-context.vala',
  'application/application-email-store-factory.vala',
  'application/application-folder-context.vala',
  'application/application-folder-plugin-context.vala',
  'application/application-folder-store-factory.vala',
  'application/application-main-window.vala',
  'application/application-notification-plugin-context.vala',
  'application/application-plugin-manager.vala',
  'application/application-startup-manager.vala',
  'application/secret-mediator.vala',

  'accounts/accounts-autoconfig.vala',
  'accounts/accounts-editor.vala',
  'accounts/accounts-editor-add-pane.vala',
  'accounts/accounts-editor-edit-pane.vala',
  'accounts/accounts-editor-list-pane.vala',
  'accounts/accounts-editor-servers-pane.vala',
  'accounts/accounts-mailbox-editor-dialog.vala',
  'accounts/accounts-service-information-widget.vala',
  'accounts/accounts-signature-web-view.vala',
  'accounts/accounts-tls-combo-row.vala',
  'accounts/accounts-manager.vala',

  'client-action.vala',

  'components/components-attachment-pane.vala',
  'components/components-conversation-actions.vala',
  'components/components-entry-undo.vala',
  'components/components-headerbar-conversation.vala',
  'components/components-info-bar-stack.vala',
  'components/components-info-bar.vala',
  'components/components-inspector.vala',
  'components/components-inspector-error-view.vala',
  'components/components-inspector-log-view.vala',
  'components/components-inspector-system-view.vala',
  'components/components-placeholder-pane.vala',
  'components/components-preferences-dialog.vala',
  'components/components-problem-report-info-bar.vala',
  'components/components-search-bar.vala',
  'components/components-validator.vala',
  'components/components-validator-group.vala',
  'components/components-web-view.vala',
  'components/count-badge.vala',
  'components/folder-popover.vala',
  'components/folder-popover-row.vala',
  'components/monitored-progress-bar.vala',
  'components/stock.vala',

  'composer/composer-addresses-row.vala',
  'composer/composer-application-interface.vala',
  'composer/composer-box.vala',
  'composer/composer-container.vala',
  'composer/composer-editor.vala',
  'composer/composer-embed.vala',
  'composer/composer-headerbar.vala',
  'composer/composer-link-popover.vala',
  'composer/composer-web-view.vala',
  'composer/composer-widget.vala',
  'composer/composer-window.vala',
  'composer/spell-check-popover.vala',

  'conversation-list/conversation-list-model.vala',
  'conversation-list/conversation-list-participant.vala',
  'conversation-list/conversation-list-row.vala',
  'conversation-list/conversation-list-view.vala',

  'conversation-viewer/conversation-contact-popover.vala',
  'conversation-viewer/conversation-email.vala',
  'conversation-viewer/conversation-list-box.vala',
  'conversation-viewer/conversation-message.vala',
  'conversation-viewer/conversation-viewer.vala',
  'conversation-viewer/conversation-web-view.vala',

  'dialogs/certificate-warning-dialog.vala',
  'dialogs/dialogs-problem-details-dialog.vala',
  'dialogs/password-dialog.vala',

  'folder-list/folder-list-abstract-folder-entry.vala',
  'folder-list/folder-list-account-branch.vala',
  'folder-list/folder-list-folder-entry.vala',
  'folder-list/folder-list-pending-folder-entry.vala',
  'folder-list/folder-list-tree.vala',
  'folder-list/folder-list-inboxes-branch.vala',
  'folder-list/folder-list-inbox-folder-entry.vala',
  'folder-list/folder-list-search-branch.vala',
  'folder-list/folder-list-special-grouping.vala',

  'plugin/plugin-account.vala',
  'plugin/plugin-action-bar.vala',
  'plugin/plugin-actionable.vala',
  'plugin/plugin-application.vala',
  'plugin/plugin-composer.vala',
  'plugin/plugin-contact-store.vala',
  'plugin/plugin-email-extension.vala',
  'plugin/plugin-email-store.vala',
  'plugin/plugin-email.vala',
  'plugin/plugin-error.vala',
  'plugin/plugin-folder-extension.vala',
  'plugin/plugin-folder-store.vala',
  'plugin/plugin-folder.vala',
  'plugin/plugin-info-bar.vala',
  'plugin/plugin-notification-extension.vala',
  'plugin/plugin-plugin-base.vala',
  'plugin/plugin-trusted-extension.vala',

  'sidebar/sidebar-branch.vala',
  'sidebar/sidebar-common.vala',
  'sidebar/sidebar-entry.vala',
  'sidebar/sidebar-tree.vala',

  'util/util-cache.vala',
  'util/util-contact.vala',
  'util/util-date.vala',
  'util/util-email.vala',
  'util/util-files.vala',
  'util/util-gio.vala',
  'util/util-gtk.vala',
  'util/util-i18n.vala',
  'util/util-js.vala',
  'util/util-migrate.vala',
)

# The native web view is per-platform: same class name and API, one
# implementation per host system. See
# components/components-native-web-view-webkit.vala.
native_web_view_sources = {
  'windows': ['components/components-native-web-view-win32.vala'],
  'darwin': ['components/components-native-web-view-darwin.vala'],
}.get(
  host_machine.system(),
  ['components/components-native-web-view-webkit.vala'],
)
client_vala_sources += files(native_web_view_sources)

client_vala_sources += files('application/goa-mediator.vala')

# Where a library the client uses is unavailable, a stub supplies the
# symbols it needs so the code above compiles unmodified. Each file
# documents what is lost. See the have_* flags in meson.build.
if not have_folks
  client_vala_sources += files('application/application-folks-stub.vala')
endif
if not have_goa
  client_vala_sources += files('application/application-goa-stub.vala')
endif
if not have_gcr
  client_vala_sources += files('application/application-gcr-stub.vala')
endif
if not have_webkit
  client_vala_sources += files('util/util-jsc-stub.vala')
endif

client_dependencies = [
  config_dep,
  enchant,
  engine_dep,
  gee,
  gio,
  gmime,
  gtk,
  icu_uc,
  json_glib,
  libadwaita,
  libmath,
  libpeas,
  libsecret,
  libsoup,
  libspelling,
  libxml,
  posix,
]

# Each of these also defines a matching HAVE_* symbol for the Vala
# compiler, so the code can do without the library. See meson.build.
client_vala_defines = []
if have_webkit
  client_dependencies += [ javascriptcoregtk, webkitgtk ]
  client_vala_defines += '--define=HAVE_WEBKIT'
endif
if have_goa
  client_dependencies += goa
  client_vala_defines += '--define=HAVE_GOA'
endif
if have_folks
  client_dependencies += folks
  client_vala_defines += '--define=HAVE_FOLKS'
endif
if have_gcr
  client_dependencies += [ gck, gcr ]
  client_vala_defines += '--define=HAVE_GCR'
endif
if have_posix
  client_vala_defines += '--define=HAVE_POSIX'
endif

client_build_dir = meson.current_build_dir()

# Generate internal VAPI for unit testing. See Meson issue
# https://github.com/mesonbuild/meson/issues/1781 for official
# internal VAPI support.
client_vala_args = convey_vala_args
client_vala_args += client_vala_defines
client_vala_args += [
  '--internal-header=@0@/@1@-internal.h'.format(
    client_build_dir, client_package_name
  ),
  '--internal-vapi=@0@/@1@-internal.vapi'.format(
    client_build_dir, client_package_name
  )
]

if have_webkit and webkitgtk.version().version_compare('<2.31')
  client_vala_args += [ '--define=WEBKIT_PLUGINS_SUPPORTED' ]
endif

# Main client application library
client_lib = shared_library(
  client_package,
  client_vala_sources + convey_resources,
  dependencies: client_dependencies,
  vala_args: client_vala_args,
  c_args: convey_c_args,
  install: true,
  install_dir: client_lib_dir,
)

# Dummy target to tell Meson about the internal VAPI given the
# workaround above, and fix the VAPI header to work around
# GNOME/vala#358
client_internal_header_fixup = custom_target(
  'client_internal_header_fixup',
  output: [
    'convey-client-internal.h',
    'convey-client-internal.vapi',
  ],
  command: [
    find_program('sed'),
    '-ibak',
    's/@0@.h/convey-client-internal.h/g'.format(client_package),
    '@OUTDIR@/convey-client-internal.vapi',
  ],
  depends: client_lib
)

client_dep = declare_dependency(
  link_with: [
    client_lib,
  ],
  include_directories: include_directories('.')
)

client_internal_dep = declare_dependency(
  # Can't just include client_lib in link_with since that will
  # pull in the public header and we get duplicate symbol errors.
  link_args: [
    '-L' + client_build_dir,
    '-l' + client_package
  ],
  include_directories: include_directories('.'),
  sources: client_internal_header_fixup
)

subdir('plugin')
