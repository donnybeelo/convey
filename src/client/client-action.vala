/*
 * Copyright 2019-2021 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/** Common client GAction and action group names */
namespace Action {


    /** Common application GAction names. */
    namespace Application {

        /** Application GAction group name */
        public const string GROUP_NAME = "app";

        public const string ABOUT = "about";
        public const string ACCOUNTS = "accounts";
        public const string COMPOSE = "compose";
        public const string IMPORT_PGP_KEY = "import-pgp-key";
        public const string INSPECT = "inspect";
        public const string HELP = "help";
        public const string MAILTO = "mailto";
        public const string NEW_WINDOW = "new-window";
        public const string PREFERENCES = "preferences";
        public const string SHOW_EMAIL = "show-email";
        public const string SHOW_FOLDER = "show-folder";
        public const string SHORTCUTS = "shortcuts";
        public const string QUIT = "quit";


        /** Returns the given action name prefixed with the group name. */
        public string prefix(string action_name) {
            return GROUP_NAME + "." + action_name;
        }

    }


    /** Common window GAction names. */
    namespace Window {

        /** Window GAction group name */
        public const string GROUP_NAME = "win";

        public const string CLOSE = "close";
        public const string SHOW_MENU = "show-menu";


        /** Returns the given action name prefixed with the group name. */
        public string prefix(string action_name) {
            return GROUP_NAME + "." + action_name;
        }

    }

    /** Common editing GAction names. */
    namespace Edit {

        /** Editing GAction group name */
        public const string GROUP_NAME = "edt";

        public const string COPY = "copy";
        public const string REDO = "redo";
        public const string UNDO = "undo";


        /** Returns the given action name prefixed with the group name. */
        public string prefix(string action_name) {
            return GROUP_NAME + "." + action_name;
        }

        /**
         * Binds Undo and Redo locally to a widget's own edit actions.
         *
         * GtkApplication accelerators are activated on the window, so
         * `edt.undo` always resolves against the window's action group,
         * no matter what has focus. Any widget that installs its own
         * edit action group therefore needs a local shortcut controller
         * to get first refusal on Ctrl+Z, otherwise the accelerator
         * falls through to whatever the window does.
         */
        public void bind_undo_shortcuts(Gtk.Widget? widget) {
            if (widget == null) {
                return;
            }

            var controller = new Gtk.ShortcutController();
            controller.scope = Gtk.ShortcutScope.LOCAL;
            controller.add_shortcut(
                new Gtk.Shortcut(
                    Gtk.ShortcutTrigger.parse_string("<Ctrl>z"),
                    new Gtk.NamedAction(prefix(UNDO))
                )
            );
            controller.add_shortcut(
                new Gtk.Shortcut(
                    Gtk.ShortcutTrigger.parse_string("<Ctrl><Shift>z"),
                    new Gtk.NamedAction(prefix(REDO))
                )
            );
            widget.add_controller(controller);
        }

    }

}
