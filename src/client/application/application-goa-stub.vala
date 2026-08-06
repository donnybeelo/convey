/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Stand-in for the parts of GNOME Online Accounts that the client uses.
 *
 * GOA is a GNOME service reached over D-Bus, so it exists on Linux only.
 * This file is compiled //only// where GOA is unavailable, so that
 * {@link Application.GoaMediator} and {@link Accounts.Manager} build
 * unmodified, and is never compiled alongside the real library. See
 * `have_goa` in meson.build.
 *
 * The client asks GOA for accounts the desktop already knows about,
 * including their OAuth2 tokens. Here there are none: the aggregator
 * returns an empty list, so only accounts the user configures in Convey
 * itself appear. Nothing is lost for those.
 *
 * A real replacement is not a GOA port but a native equivalent: on
 * Windows, the accounts registered with the system through the Web
 * Account Manager, and on macOS the accounts in System Settings. Both
 * would supply the same thing this shape describes — a host, a user
 * name, and a token — so the two callers above can stay
 * platform-independent.
 */
namespace Goa {

    /** Errors reported by the accounts service. */
    public errordomain Error {
        FAILED,
        NOT_AUTHORIZED;
    }

    /** An account's mail endpoint configuration. */
    public class Mail : GLib.Object {

        public string email_address { get; default = ""; }

        public string imap_host { get; default = ""; }
        public string imap_user_name { get; default = ""; }
        public bool imap_use_ssl { get; default = false; }
        public bool imap_use_tls { get; default = false; }

        public string smtp_host { get; default = ""; }
        public string smtp_user_name { get; default = ""; }
        public bool smtp_use_auth { get; default = false; }
        public bool smtp_use_ssl { get; default = false; }
        public bool smtp_use_tls { get; default = false; }

    }

    /** An account's identity, as the desktop knows it. */
    public class Account : GLib.Object {

        public string id { get; default = ""; }
        public string provider_type { get; default = ""; }
        public string presentation_identity { get; default = ""; }

        public async void call_ensure_credentials(
            GLib.Cancellable? cancellable, out int expires_in = null
        ) throws GLib.Error {
            expires_in = 0;
            throw new Goa.Error.NOT_AUTHORIZED(
                "No desktop accounts service on this platform"
            );
        }

    }

    /** An account's OAuth2 credentials. */
    public class OAuth2Based : GLib.Object {

        public async void call_get_access_token(
            GLib.Cancellable? cancellable,
            out string access_token,
            out int expires_in
        ) throws GLib.Error {
            access_token = "";
            expires_in = 0;
            throw new Goa.Error.NOT_AUTHORIZED(
                "No desktop accounts service on this platform"
            );
        }

    }

    /** A single account known to the accounts service. */
    public class Object : GLib.Object {

        public Account? get_account() {
            return null;
        }

        public Mail? get_mail() {
            return null;
        }

        public OAuth2Based? get_oauth2_based() {
            return null;
        }

    }

    /** The accounts service itself. */
    public class Client : GLib.Object {

        /** Emitted when the desktop gains an account. */
        public signal void account_added(Object account);

        /** Emitted when one of the desktop's accounts changes. */
        public signal void account_changed(Object account);

        /** Emitted when the desktop loses an account. */
        public signal void account_removed(Object account);

        public async Client(GLib.Cancellable? cancellable) throws GLib.Error {
        }

        public GLib.List<Object> get_accounts() {
            return new GLib.List<Object>();
        }

    }

}
