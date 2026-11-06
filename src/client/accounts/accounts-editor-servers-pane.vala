/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2018-2019 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * An account editor pane for editing server details for an account.
 */
[GtkTemplate (ui = "/net/donnybeelo/Convey/accounts_editor_servers_pane.ui")]
internal class Accounts.EditorServersPane : EditorPane, AccountPane, CommandPane {


    /** {@inheritDoc} */
    internal override weak Accounts.Editor editor { get; set; }

    /** {@inheritDoc} */
    internal Convey.AccountInformation account { get ; protected set; }

    /** {@inheritDoc} */
    internal Application.CommandStack commands {
        get; protected set; default = new Application.CommandStack();
    }

    /** {@inheritDoc} */
    internal override bool is_operation_running {
        get { return !this.sensitive; }
        protected set { update_operation_ui(value); }
    }

    /** {@inheritDoc} */
    internal override Cancellable? op_cancellable {
        get; protected set; default = new GLib.Cancellable();
    }

    private Convey.Engine engine;


    [GtkChild] private unowned Adw.ActionRow account_provider_row;
    [GtkChild] private unowned Adw.ActionRow service_provider_row;
    [GtkChild] private unowned Adw.SwitchRow save_drafts_row;
    [GtkChild] private unowned Adw.SwitchRow save_sent_row;

    [GtkChild] private unowned ServiceInformationWidget receiving_service_widget;
    [GtkChild] private unowned ServiceInformationWidget sending_service_widget;

    [GtkChild] private unowned Gtk.Button apply_button;
    [GtkChild] private unowned Gtk.Spinner apply_spinner;


    static construct {
        typeof(ServiceInformationWidget).ensure();

        install_action("apply", null, (Gtk.WidgetActionActivateFunc) action_apply);
    }


    public EditorServersPane(Editor editor, Convey.AccountInformation account) {
        this.editor = editor;
        this.account = account;
        this.engine = editor.application.engine;


        // Details
        fill_in_account_provider(editor.accounts);
        fill_in_service_provider();

        this.receiving_service_widget.service = account.incoming;
        this.sending_service_widget.service = account.outgoing;

        bool services_editable = !(account.mediator is GoaMediator);
        this.receiving_service_widget.set_editable(services_editable);
        this.sending_service_widget.set_editable(services_editable);

        this.save_drafts_row.active = account.save_drafts;
        this.save_sent_row.active = account.save_sent;

        // The switch rows aren't on the command stack, so
        // just enable Apply directly rather than wrapping them in
        // undoable commands
        this.save_drafts_row.notify["active"].connect(enable_apply);
        this.save_sent_row.notify["active"].connect(enable_apply);

        // GMail and Outlook auto-save sent mail so don't include the
        // save sent option for them
        this.save_sent_row.visible = (account.service_provider == OTHER);

        // Misc plumbing

        connect_account_signals();
        connect_command_signals();
    }

    ~EditorServersPane() {
        disconnect_account_signals();
        disconnect_command_signals();
    }

    private void fill_in_account_provider(Manager accounts) {
        if (this.account.mediator is GoaMediator) {
            this.account_provider_row.subtitle = _("GNOME Online Accounts");

            var button = new Gtk.Button.from_icon_name("document-edit-symbolic");
            button.valign = Gtk.Align.CENTER;
            button.clicked.connect((button) => {
                if (accounts.is_goa_account(this.account)) {
                    accounts.show_goa_account.begin(
                        account, this, this.op_cancellable,
                        (obj, res) => {
                            try {
                                accounts.show_goa_account.end(res);
                            } catch (GLib.Error err) {
                                this.editor.add_toast(
                                    new Adw.Toast(
                                        // Translators: In-app
                                        // notification label, when
                                        // the GNOME Online Accounts
                                        // panel could not be shown
                                        _("Unable to open GNOME Online Accounts")
                                    )
                                );
                                debug(
                                    "Failed to show GOA account \"%s\": %s",
                                    account.id,
                                    err.message
                                );
                            }
                        });
                }
            });
            this.account_provider_row.add_suffix(button);
        }
    }

    private void fill_in_service_provider() {
        switch (this.account.service_provider) {
        case Convey.ServiceProvider.GMAIL:
            this.service_provider_row.subtitle = _("Gmail");
            break;

        case Convey.ServiceProvider.OUTLOOK:
            this.service_provider_row.subtitle = _("Outlook.com");
            break;

        case Convey.ServiceProvider.OTHER:
            this.service_provider_row.subtitle = this.account.service_label;
            break;
        }
    }

    private void enable_apply() {
        this.apply_button.sensitive = true;
    }

    /** {@inheritDoc} */
    protected void command_executed() {
        this.editor.update_command_actions();
        this.apply_button.set_sensitive(this.commands.can_undo);
    }

    private async void save(GLib.Cancellable? cancellable) {
        this.is_operation_running = true;

        // Only need to validate if a generic, local account since
        // other account types have read-only incoming/outgoing
        // settings
        bool is_valid = true;
        bool has_changed = false;
        if (this.account.service_provider == Convey.ServiceProvider.OTHER &&
            !this.editor.accounts.is_goa_account(this.account)) {
            // Pull the entered field values into the service objects
            // before validating and saving.
            this.receiving_service_widget.update_service_from_ui();
            this.sending_service_widget.update_service_from_ui();

            is_valid = yield validate(cancellable);
            if (is_valid) {
                has_changed |= yield update_service(
                    this.account.incoming,
                    this.receiving_service_widget.service_mutable,
                    cancellable
                );
                has_changed |= yield update_service(
                    this.account.outgoing,
                    this.sending_service_widget.service_mutable,
                    cancellable
                );
            }
        }

        this.is_operation_running = false;

        if (is_valid) {
            if (this.save_drafts_row.active != this.account.save_drafts) {
                this.account.save_drafts = this.save_drafts_row.active;
                has_changed = true;
            }
            if (this.save_sent_row.active != this.account.save_sent) {
                this.account.save_sent = this.save_sent_row.active;
                has_changed = true;
            }

            if (has_changed) {
                this.account.changed();
            }

            this.editor.pop_pane();
        } else {
            // Re-enable apply so that the same config can be re-tried
            // in the face of transient errors, without having to
            // change something to re-enable it
            this.apply_button.sensitive = true;
        }
    }

    private async bool validate(GLib.Cancellable? cancellable) {
        // Use a copy here so we can handle any prompting needed
        // (auth, certs) directly, rather than through the main window
        Convey.AccountInformation local_account =
            new Convey.AccountInformation.copy(this.account);
        local_account.untrusted_host.connect(on_untrusted_host);

        string? message = null;
        bool imap_valid = false;

        try {
            yield this.engine.validate_imap(
                local_account,
                this.receiving_service_widget.service_mutable,
                cancellable
            );
            imap_valid = true;
        } catch (Convey.ImapError.UNAUTHENTICATED err) {
            debug("Error authenticating IMAP service: %s", err.message);
            // Translators: In-app notification label
            message = _("Check your receiving login and password");
        } catch (GLib.TlsError.BAD_CERTIFICATE err) {
            // Nothing to do here, since the untrusted host
            // handler will be dealing with it
            debug("Error validating IMAP certificate: %s", err.message);
        } catch (GLib.IOError.CANCELLED err) {
            // Nothing to do here, someone just cancelled
            debug("IMAP validation was cancelled: %s", err.message);
        } catch (GLib.Error err) {
            Convey.ErrorContext context = new Convey.ErrorContext(err);
            debug("Error validating IMAP service: %s",
                  context.format_full_error());
            // Translators: In-app notification label
            message = _("Check your receiving server details");
        }

        bool smtp_valid = false;
        if (imap_valid) {
            debug("Validating SMTP...");
            try {
                yield this.engine.validate_smtp(
                    local_account,
                    this.sending_service_widget.service_mutable,
                    this.receiving_service_widget.service_mutable.credentials,
                    cancellable
                );
                smtp_valid = true;
            } catch (Convey.SmtpError.AUTHENTICATION_FAILED err) {
                debug("Error authenticating SMTP service: %s", err.message);
                // There was an SMTP auth error, but IMAP already
                // succeeded, so the user probably needs to
                // specify custom creds here
                this.sending_service_widget.require_custom_credentials();
                // Translators: In-app notification label
                message = _("Check your sending login and password");
            } catch (GLib.TlsError.BAD_CERTIFICATE err) {
                // Nothing to do here, since the untrusted host
                // handler will be dealing with it
                debug("Error validating SMTP certificate: %s", err.message);
            } catch (GLib.IOError.CANCELLED err) {
                // Nothing to do here, someone just cancelled
                debug("SMTP validation was cancelled: %s", err.message);
            } catch (GLib.Error err) {
                Convey.ErrorContext context = new Convey.ErrorContext(err);
                debug("Error validating SMTP service: %s",
                      context.format_full_error());
                // Translators: In-app notification label
                message = _("Check your sending server details");
            }
        }

        local_account.untrusted_host.disconnect(on_untrusted_host);

        bool is_valid = imap_valid && smtp_valid;
        debug("Validation complete, is valid: %s", is_valid.to_string());

        if (!is_valid && message != null) {
            this.editor.add_toast(
                new Adw.Toast(
                    // Translators: In-app notification label, the
                    // string substitution is a more detailed reason.
                    _("Account not updated: %s").printf(message)
                )
            );
        }

        return is_valid;
    }

    private async bool update_service(Convey.ServiceInformation existing,
                                      Convey.ServiceInformation copy,
                                      GLib.Cancellable cancellable) {
        bool has_changed = !existing.equal_to(copy);
        if (has_changed) {
            try {
                yield this.editor.accounts.update_local_credentials(
                    this.account, existing, copy, cancellable
                );
            } catch (GLib.Error err) {
                warning(
                    "Could not update %s %s credentials: %s",
                    this.account.id,
                    existing.protocol.to_value(),
                    err.message
                );
            }

            try {
                yield this.engine.update_account_service(
                    this.account, copy, cancellable
                );
            } catch (GLib.Error err) {
                warning(
                    "Could not update %s %s service: %s",
                    this.account.id,
                    existing.protocol.to_value(),
                    err.message
                );
            }
        }
        return has_changed;
    }

    private void update_operation_ui(bool is_running) {
        this.apply_spinner.visible = is_running;
        this.apply_button.sensitive = !is_running;
        this.sensitive = !is_running;
    }

    // Apply is deliberately not gated on the field validators: host
    // validation does a DNS lookup, so gating would lock people out
    // when offline or behind split DNS. The validators show inline
    // feedback and apply() re-enables the button after a failure.

    private void on_untrusted_host(Convey.AccountInformation account,
                                   Convey.ServiceInformation service,
                                   Convey.Endpoint endpoint,
                                   GLib.TlsConnection cx) {
        this.editor.prompt_pin_certificate.begin(
            account, service, endpoint, null,
            (obj, res) => {
                try {
                    this.editor.prompt_pin_certificate.end(res);
                } catch (Application.CertificateManagerError err) {
                    // All good, just drop back into the editor
                    // window.
                    return;
                }

                // Kick off another attempt to save
                this.save.begin(null);
            });
    }

    private void action_apply(string action_name, Variant? param) {
        this.save.begin(this.op_cancellable);
    }

}

