/*
 * Copyright 2018-2019 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * An account editor pane for adding a new account.
 */
[GtkTemplate (ui = "/net/donnybeelo/Convey/accounts_editor_add_pane.ui")]
internal class Accounts.EditorAddPane : Accounts.EditorPane {


    /** {@inheritDoc} */
    internal override bool is_operation_running {
        get { return !this.sensitive; }
        protected set { update_operation_ui(value); }
    }

    /** {@inheritDoc} */
    internal override Cancellable? op_cancellable {
        get; protected set; default = new GLib.Cancellable();
    }

    protected override weak Accounts.Editor editor { get; set; }

    private Convey.ServiceProvider provider;

    private Manager accounts;
    private Convey.Engine engine;



    [GtkChild] private unowned Gtk.Stack stack;

    [GtkChild] private unowned Adw.EntryRow name_row;
    [GtkChild] private unowned Adw.EntryRow email_row;
    [GtkChild] private unowned Components.Validator email_validator;

    [GtkChild] private unowned ServiceInformationWidget receiving_service_widget;
    [GtkChild] private unowned ServiceInformationWidget sending_service_widget;

    [GtkChild] private unowned Gtk.Button action_button;
    [GtkChild] private unowned Adw.Spinner action_spinner;

    private string last_valid_email = "";
    private string last_valid_hostname = "";

    // When set, the server rows are hidden; see
    // set_server_settings_from_autoconfig.
    private bool did_auto_config { get; private set; default = false; }
    private GLib.Cancellable auto_config_cancellable = new GLib.Cancellable();

    private bool controls_valid = false;

    public Components.ValidatorGroup validators { get; construct set; }


    static construct {
        typeof(Components.ValidatorGroup).ensure();
        typeof(Components.Validator).ensure();
        typeof(Components.EmailValidator).ensure();
    }

    internal EditorAddPane(Editor editor) {
        Object(editor: editor);

        this.provider = Convey.ServiceProvider.OTHER;

        this.accounts = editor.application.controller.account_manager;
        this.engine = editor.application.engine;

        this.name_row.text = this.accounts.get_account_name();

        this.receiving_service_widget.service = new_imap_service();
        this.sending_service_widget.service = new_smtp_service();

        // The validator group declared under the "validators" property
        // in the .ui does not survive GtkBuilder template construction
        // (the property is null at runtime), so build it here and wire
        // the email field to it. The Next button becomes sensitive once
        // a valid email address has been entered.
        this.validators = new Components.ValidatorGroup();
        this.validators.add_validator(this.email_validator);
        this.validators.changed.connect((v) => check_validation());
        this.validators.activated.connect((v) => on_activated());

        check_validation();
    }

    private async void validate_account(GLib.Cancellable? cancellable) {
        this.is_operation_running = true;

        bool is_valid = false;
        string? message = null;
        Gtk.Widget? to_focus = null;

        Convey.AccountInformation account =
            yield this.accounts.new_orphan_account(
                this.provider,
                new Convey.RFC822.MailboxAddress(
                    this.name_row.text.strip(),
                    this.email_row.text.strip()
                ),
                cancellable
            );

        // The service widgets are display-only; pull the entered field
        // values into their service objects before validating.
        this.receiving_service_widget.update_service_from_ui();
        this.sending_service_widget.update_service_from_ui();

        account.incoming = this.receiving_service_widget.service_mutable;
        account.outgoing = this.sending_service_widget.service_mutable;
        account.untrusted_host.connect(on_untrusted_host);

        if (this.provider == Convey.ServiceProvider.OTHER &&
                !this.did_auto_config) {
            bool imap_valid = false;
            bool smtp_valid = false;

            try {
                yield this.engine.validate_imap(
                    account, account.incoming, cancellable
                );
                imap_valid = true;
            } catch (Convey.ImapError.UNAUTHENTICATED err) {
                debug("Error authenticating IMAP service: %s", err.message);
                to_focus = this.receiving_service_widget;
                // Translators: In-app notification label
                message = _("Check your receiving login and password");
            } catch (GLib.TlsError.BAD_CERTIFICATE err) {
                debug("Error validating IMAP certificate: %s", err.message);
                // Nothing to do here, since the untrusted host
                // handler will be dealing with it
            } catch (GLib.IOError.CANCELLED err) {
                // Nothing to do here, someone just cancelled
                debug("IMAP validation was cancelled: %s", err.message);
            } catch (GLib.Error err) {
                Convey.ErrorContext context = new Convey.ErrorContext(err);
                debug("Error validating IMAP service: %s",
                      context.format_full_error());
                // Reveal the server rows so the user can correct
                // whatever autoconfig guessed wrong.
                this.receiving_service_widget.set_server_details_visible(true);
                to_focus = this.receiving_service_widget;
                // Translators: In-app notification label
                message = _("Check your receiving server details");
            }

            if (imap_valid) {
                debug("Validating SMTP...");
                try {
                    yield this.engine.validate_smtp(
                        account,
                        account.outgoing,
                        account.incoming.credentials,
                        cancellable
                    );
                    smtp_valid = true;
                } catch (Convey.SmtpError.AUTHENTICATION_FAILED err) {
                    debug("Error authenticating SMTP service: %s", err.message);
                    // There was an SMTP auth error, but IMAP already
                    // succeeded, so the user probably needs to
                    // specify custom creds here
                    this.sending_service_widget.require_custom_credentials();
                    to_focus = this.sending_service_widget;
                    // Translators: In-app notification label
                    message = _("Check your sending login and password");
                } catch (GLib.TlsError.BAD_CERTIFICATE err) {
                    // Nothing to do here, since the untrusted host
                    // handler will be dealing with it
                } catch (GLib.IOError.CANCELLED err) {
                    // Nothing to do here, someone just cancelled
                    debug("SMTP validation was cancelled: %s", err.message);
                } catch (GLib.Error err) {
                    Convey.ErrorContext context = new Convey.ErrorContext(err);
                    debug("Error validating SMTP service: %s",
                          context.format_full_error());
                    to_focus = this.sending_service_widget;
                    // Translators: In-app notification label
                    message = _("Check your sending server details");
                }
            }

            is_valid = imap_valid && smtp_valid;
        } else {
            try {
                yield this.engine.validate_imap(
                    account, account.incoming, cancellable
                );
                is_valid = true;
            } catch (Convey.ImapError.UNAUTHENTICATED err) {
                debug("Error authenticating provider: %s", err.message);
                to_focus = this.email_row;
                // Translators: In-app notification label
                message = _("Check your email address and password");
            } catch (GLib.TlsError.BAD_CERTIFICATE err) {
                // Nothing to do here, since the untrusted host
                // handler will be dealing with it
                debug("Error validating SMTP certificate: %s", err.message);
            } catch (GLib.Error err) {
                Convey.ErrorContext context = new Convey.ErrorContext(err);
                debug("Error validating SMTP service: %s",
                      context.format_full_error());
                is_valid = false;
                // Translators: In-app notification label
                message = _("Could not connect, check your network");
            }
        }

        if (is_valid) {
            try {
                yield this.accounts.create_account(account, cancellable);
                this.editor.pop_pane();
            } catch (GLib.Error err) {
                debug("Failed to create new local account: %s", err.message);
                is_valid = false;
                // Translators: In-app notification label for a
                // generic error creating an account
                message = _("An unexpected problem occurred");
            }
        }

        account.untrusted_host.disconnect(on_untrusted_host);
        this.is_operation_running = false;

        // Focus and pop up the notification after re-sensitising
        // so it actually succeeds.
        if (!is_valid) {
            if (to_focus != null) {
                to_focus.grab_focus();
            }
            if (message != null) {
                this.editor.add_toast(
                    new Adw.Toast(
                        // Translators: In-app notification label, the
                        // string substitution is a more detailed reason.
                        _("Account not created: %s").printf(message)
                    )
                );
            }
        }
    }

    private Convey.ServiceInformation new_imap_service() {
        var service = new Convey.ServiceInformation(
            Convey.Protocol.IMAP, this.provider
        );
        service.credentials = new Convey.Credentials(
            Convey.Credentials.Method.PASSWORD, ""
        );
        return service;
    }

    private Convey.ServiceInformation new_smtp_service() {
        return new Convey.ServiceInformation(
            Convey.Protocol.SMTP, this.provider
        );
    }

    private void check_validation() {
        // On the server settings page the Create button stays enabled;
        // validate_account() performs the real connection check and
        // reports failures in-line. On the initial user settings page,
        // gate Next on a non-empty name and a valid email address.
        bool controls_valid =
            this.stack.get_visible_child_name() == "server_settings"
            || this.validators.is_valid();
        this.action_button.set_sensitive(controls_valid);
        this.controls_valid = controls_valid;
    }

    private void update_operation_ui(bool is_running) {
        this.action_spinner.visible = is_running;
        this.action_button.sensitive = !is_running;
        this.sensitive = !is_running;
    }

    private void switch_to_user_settings() {
        this.stack.set_visible_child_name("user_settings");
        this.action_button.set_label(_("_Next"));
        this.action_button.set_sensitive(true);
        this.action_button.remove_css_class("suggested-action");
    }

    private void switch_to_server_settings() {
        this.stack.set_visible_child_name("server_settings");
        this.action_button.set_label(_("_Create"));
        this.action_button.add_css_class("suggested-action");
        check_validation();
    }

    private void set_server_settings_from_autoconfig(AutoConfig auto_config,
                                                     GLib.AsyncResult res)
            throws Accounts.AutoConfigError {
        AutoConfigValues auto_config_values = auto_config.get_config.end(res);

        Convey.ServiceInformation imap_service = this.receiving_service_widget.service;
        Convey.ServiceInformation smtp_service = this.sending_service_widget.service;

        imap_service.host = auto_config_values.imap_server;
        imap_service.port = (uint16) uint.parse(auto_config_values.imap_port);
        imap_service.transport_security = auto_config_values.imap_tls_method;

        smtp_service.host = auto_config_values.smtp_server;
        smtp_service.port = (uint16) uint.parse(auto_config_values.smtp_port);
        smtp_service.transport_security = auto_config_values.smtp_tls_method;

        // Autoconfig found the servers, so there's nothing useful for
        // the user to change here.
        this.receiving_service_widget.set_server_details_visible(false);
        this.sending_service_widget.set_server_details_visible(false);

        switch (auto_config_values.id) {
        case "googlemail.com":
            this.provider = Convey.ServiceProvider.GMAIL;
            break;
        case "hotmail.com":
            this.provider = Convey.ServiceProvider.OUTLOOK;
            break;
        default:
            this.provider = Convey.ServiceProvider.OTHER;
            break;
        }
    }

    private void set_server_settings_from_hostname(string hostname) {
        Convey.ServiceInformation imap_service = this.receiving_service_widget.service;
        Convey.ServiceInformation smtp_service = this.sending_service_widget.service;
        string smtp_hostname = "smtp." + hostname;
        string imap_hostname = "imap." + hostname;
        string last_imap_hostname = "";
        string last_smtp_hostname = "";

        // Guessing from the hostname, so the user needs to be able to
        // correct us.
        this.receiving_service_widget.set_server_details_visible(true);
        this.sending_service_widget.set_server_details_visible(true);

        if (this.last_valid_hostname != "") {
            last_imap_hostname = "imap." + this.last_valid_hostname;
            last_smtp_hostname = "smtp." + this.last_valid_hostname;
        }
        if (imap_service.host == last_imap_hostname) {
            imap_service.host = imap_hostname;
        }
        if (smtp_service.host == last_smtp_hostname) {
            smtp_service.host = smtp_hostname;
        }
        this.last_valid_hostname = hostname;
    }

    [GtkCallback]
    private void on_validated(Components.ValidatorGroup validators,
                              Components.Validator validator) {
        check_validation();
        // Activating (Enter) is handled by on_activated, wired to the
        // validator group's "activated" signal.
    }

    [GtkCallback]
    private void on_activated() {
        if (this.controls_valid) {
            this.action_button.clicked();
        }
    }

    [GtkCallback]
    private void on_email_row_changed(Gtk.Editable editable) {
        var imap_service = this.receiving_service_widget.service;
        var smtp_service = this.sending_service_widget.service;

        this.auto_config_cancellable.cancel();

        if (this.email_validator.state != Components.Validator.Validity.VALID) {
            return;
        }

        string email = this.email_row.text;
        string hostname = email.split("@")[1];

        // Do not update entries if changed by user
        if (imap_service.credentials == null ||
            imap_service.credentials.user == this.last_valid_email) {
            imap_service.credentials = new Convey.Credentials(
                Convey.Credentials.Method.PASSWORD, email
            );
        }
        if (smtp_service.credentials == null ||
            smtp_service.credentials.user == this.last_valid_email) {
            smtp_service.credentials = new Convey.Credentials(
                Convey.Credentials.Method.PASSWORD, email
            );
        }

        this.last_valid_email = email;

        // Try to get configuration from Thunderbird autoconfig service
        this.action_spinner.visible = true;
        this.auto_config_cancellable = new GLib.Cancellable();
        var auto_config = new AutoConfig(this.auto_config_cancellable);
        auto_config.get_config.begin(hostname, (obj, res) => {
            try {
                set_server_settings_from_autoconfig(auto_config, res);
            } catch (Accounts.AutoConfigError err) {
                debug("Error getting auto configuration: %s", err.message);
                set_server_settings_from_hostname(hostname);
            }
            this.action_spinner.visible = false;
        });
    }

    private void on_untrusted_host(Convey.AccountInformation account,
                                   Convey.ServiceInformation service,
                                   Convey.Endpoint endpoint,
                                   GLib.TlsConnection cx) {
        this.editor.prompt_pin_certificate.begin(
            account, service, endpoint, this.op_cancellable,
            (obj, res) => {
                try {
                    this.editor.prompt_pin_certificate.end(res);
                } catch (Application.CertificateManagerError err) {
                    // All good, just drop back into the editor
                    // window.
                    return;
                }

                // Kick off another attempt to validate
                this.validate_account.begin(this.op_cancellable);
            });
    }

    [GtkCallback]
    private void on_action_button_clicked() {
        if (this.stack.get_visible_child_name() == "user_settings") {
            switch_to_server_settings();
        } else {
            this.validate_account.begin(this.op_cancellable);
        }
    }
}
