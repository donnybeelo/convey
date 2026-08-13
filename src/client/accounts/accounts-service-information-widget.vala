/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2018-2019 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * A widget for editing a {@link Convey.ServiceInformation} object.
 */
[GtkTemplate (ui = "/net/donnybeelo/Convey/accounts-service-information-widget.ui")]
internal class Accounts.ServiceInformationWidget : Adw.PreferencesGroup {

    public Convey.ServiceInformation service {
        get { return this._service; }
        set {
            this._service = value;
            this.service_mutable = new Convey.ServiceInformation.copy(value);
            update_details();
            // Take a fresh copy when the original changes, not just a
            // fresh look at the old one: the details shown and later
            // validated come from the copy, so autoconfig writing
            // servers into the original would otherwise be discarded,
            // leaving the account with no host to connect to.
            value.notify.connect((obj, pspec) => {
                    this.service_mutable =
                        new Convey.ServiceInformation.copy(this._service);
                    update_details();
                });
        }
    }
    private Convey.ServiceInformation _service;

    // A copy of the original that can be without breaking the original
    public Convey.ServiceInformation service_mutable { get ; private set; }

    public Components.ValidatorGroup validators { get; construct set; }

    [GtkChild] private unowned Adw.EntryRow host_row;
    [GtkChild] private unowned TlsComboRow security_row;
    [GtkChild] private unowned Adw.ComboRow credentials_requirement_row;
    [GtkChild] private unowned Adw.EntryRow login_name_row;
    [GtkChild] private unowned Adw.PasswordEntryRow password_row;
    [GtkChild] private unowned Components.NetworkAddressValidator host_validator;


    static construct {
        typeof(TlsComboRow).ensure();
        typeof(Components.ValidatorGroup).ensure();
        typeof(Components.Validator).ensure();
    }


    /**
     * Sets whether editing the information is possible
     */
    public void set_editable(bool editable) {
        this.sensitive = editable;
        update_details();
    }

    /**
     * Switches the outgoing service to its own login credentials.
     *
     * Used when SMTP auth fails but IMAP succeeded, so the user
     * probably needs to enter separate credentials here.
     */
    public void require_custom_credentials() {
        if (this.service_mutable.protocol != Convey.Protocol.SMTP) {
            return;
        }
        this.service_mutable.credentials_requirement =
            Convey.Credentials.Requirement.CUSTOM;
        update_auth(this.service_mutable);
    }

    /**
     * Sets whether the host and transport security rows are shown.
     *
     * These are hidden when the values were discovered by autoconfig,
     * since there is nothing useful for the user to change.
     */
    public void set_server_details_visible(bool visible) {
        this.host_row.visible = visible;
        this.security_row.visible = visible;
    }

    private void update_details() {
        // So "imap.example.com" with no port validates against the
        // right default rather than port 0.
        this.host_validator.default_port =
            this.service_mutable.get_default_port();
        update_host_row(this.host_row, this.service_mutable);
        this.security_row.method = this.service_mutable.transport_security;
        update_auth(this.service_mutable);
    }

    private void update_host_row(Adw.EntryRow row, Convey.ServiceInformation service) {
        row.title = host_label_for_protocol(service.protocol);

        row.text = service.host ?? "";
        if (!Convey.String.is_empty(service.host)) {
            // Only show the port if it not the appropriate default port
            uint16 port = service.port;
            if (port != service.get_default_port()) {
                row.text = "%s:%d".printf(service.host, service.port);
            }
        }
    }

    private string host_label_for_protocol(Convey.Protocol protocol) {
        switch (protocol) {
        case Convey.Protocol.IMAP:
            // Translators: This label describes the host name or IP
            // address and port used by an account's IMAP service.
            return _("IMAP Server");

        case Convey.Protocol.SMTP:
            // Translators: This label describes the host name or IP
            // address and port used by an account's SMTP service.
            return _("SMTP Server");
        }

        return _("Unknown Protocol");
    }

    private void update_login_name_row(Adw.EntryRow row,
                                       Convey.ServiceInformation service) {
        // Translators: Label used when no auth scheme is used
        // by an account's IMAP or SMTP service.
        row.text = _("None");

        // If we have credentials, we can do better
        if (service.credentials != null) {
            switch (service.credentials.supported_method) {
            case Convey.Credentials.Method.PASSWORD:
                row.text = service.credentials.user;
                break;

            case Convey.Credentials.Method.OAUTH2:
                // Add a suffix for OAuth2 auth so people know they
                // shouldn't expect to be prompted for a password

                // Translators: Label used when an account's IMAP or
                // SMTP service uses OAuth2. The string replacement is
                // the service's login name.
                row.text = _("%s using OAuth2").printf(service.credentials.user ?? "");
                break;
            }
        }

        // If we rely on the credentials of the incoming server, notify the user of that
        if (service.protocol == Convey.Protocol.SMTP &&
                   service.credentials_requirement ==
                   Convey.Credentials.Requirement.USE_INCOMING) {
            row.text = _("Use receiving server login");
        }
    }

    private void update_password_row(Adw.PasswordEntryRow row,
                                     Convey.ServiceInformation service) {
        if (service.credentials != null) {
            row.text = service.credentials.token ?? "";
        } else {
            row.text = "";
        }

        // If we're not enabled, the "Show Password" button is insensitive too
        // so just hide the row
        if (!this.sensitive)
            row.visible = false;
    }

    /**
     * Reads the current UI field values back into {@link service_mutable}.
     *
     * The row widgets are display-only; call this before using
     * service_mutable (e.g. before validating or saving) so it reflects
     * what the user actually entered.
     */
    public void update_service_from_ui() {
        if (this.service_mutable == null) {
            return;
        }

        string host_text = this.host_row.get_text().strip();
        if (host_text != "") {
            try {
                var addr = GLib.NetworkAddress.parse(
                    host_text, this.service_mutable.get_default_port()
                );
                this.service_mutable.host = addr.hostname;
                this.service_mutable.port = (uint16) addr.port;
            } catch (GLib.Error err) {
                // Leave the previous value; the validator flags bad input.
            }
        }

        this.service_mutable.transport_security = this.security_row.method;

        if (this.service_mutable.protocol == Convey.Protocol.SMTP) {
            this.service_mutable.credentials_requirement =
                (Convey.Credentials.Requirement) this.credentials_requirement_row.selected;
            // When the outgoing service reuses the incoming login there
            // are no separate credentials to collect here.
            if (this.service_mutable.credentials_requirement ==
                    Convey.Credentials.Requirement.USE_INCOMING) {
                return;
            }
        }

        string user = this.login_name_row.get_text().strip();
        string token = this.password_row.get_text();
        if (user != "" && user != _("None")) {
            this.service_mutable.credentials = new Convey.Credentials(
                Convey.Credentials.Method.PASSWORD, user, token
            );
        }
    }

    private void update_auth(Convey.ServiceInformation service) {
        bool is_smtp = (service.protocol == Convey.Protocol.SMTP);
        this.credentials_requirement_row.visible = is_smtp;

        if (is_smtp) {
            this.credentials_requirement_row.selected = service.credentials_requirement;

            bool needs_login =
                (service.credentials_requirement == Convey.Credentials.Requirement.CUSTOM);
            this.login_name_row.visible = needs_login;
            this.password_row.visible = needs_login;
        }

        update_login_name_row(this.login_name_row, this.service_mutable);
        update_password_row(this.password_row, this.service_mutable);
    }

    [GtkCallback]
    private static string outgoing_auth_to_string(Adw.EnumListItem item,
                                                  Convey.Credentials.Requirement requirement) {
        return requirement.to_string();
    }
}
