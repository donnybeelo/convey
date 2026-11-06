/*
 * Copyright 2017 Software Freedom Conservancy Inc.
 * Copyright 2018 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */


/**
 * Manages email account lifecycle for Convey.
 *
 * This class is responsible for creating, loading, saving and
 * removing accounts and their persisted data (configuration,
 * databases, caches, authentication tokens). The manager supports
 * both locally-specified accounts (i.e. those created by the user in
 * the app) and from SSO systems such as GOA via the Accounts.Provider
 * interface.
 *
 * Newly loaded and newly created accounts are first added to the
 * manager with a particular status (enabled, disabled, etc). Accounts
 * can have their enabled or disabled status updated manually,
 */
public class Accounts.Manager : GLib.Object {


    /** The name of the Convey configuration file. */
    public const string SETTINGS_FILENAME = "convey.ini";

    private const string LOCAL_ID_PREFIX = "account_";
    private const string LOCAL_ID_FORMAT = "account_%02u";
    private const string GOA_ID_PREFIX = "goa_";
    private const string GOA_NON_IMAP_MAIL_PROVIDER = "exchange";

    private const int CONFIG_VERSION = 1;

    private const string GROUP_METADATA = "Metadata";

    private const string METADATA_STATUS = "status";
    private const string METADATA_VERSION = "version";
    private const string METADATA_GOA = "goa_id";


    /**
     * Specifies the overall status of an account.
     */
    public enum Status {
        /** The account is enabled and operational. */
        ENABLED,

        /** The account was disabled by the user. */
        DISABLED,

        /** The account is unavailable to be used, but may come back. */
        UNAVAILABLE,

        /** The account has been removed and is scheduled for deletion. */
        REMOVED;

        public static Status for_value(string value)
        throws Convey.EngineError {
            return Convey.ObjectUtils.from_enum_nick<Status>(
                typeof(Status), value.ascii_down()
            );
        }

        public string to_value() {
            return Convey.ObjectUtils.to_enum_nick<Status>(
                typeof(Status), this
            );
        }
    }


    /** Specifies an account's current state. */
    private class AccountState {


        /** The account represented by this object. */
        public Convey.AccountInformation account { get; private set; }

        /** Determines the account's overall state. */
        public Status status {
            get {
                Status status = Status.ENABLED;
                if (!this.enabled) {
                    status = Status.DISABLED;
                }
                if (!this.available) {
                    status = Status.UNAVAILABLE;
                }
                return status;
            }
        }

        /** Whether this account is enabled. */
        public bool enabled { get; set; default = true; }

        /** Whether this account is available. */
        public bool available { get; set; default = true; }


        internal AccountState(Convey.AccountInformation account) {
            this.account = account;
        }

    }


    /** Returns the number of currently known accounts. */
    public int size { get { return this.accounts.size; } }

    /** Returns the base directory for account configuration. */
    public GLib.File config_dir { get; private set; }

    /** Returns the base directory for account data. */
    public GLib.File data_dir { get; private set; }


    private Gee.Map<string,AccountState> accounts =
        new Gee.HashMap<string,AccountState>();

    private Gee.LinkedList<Convey.AccountInformation> removed =
        new Gee.LinkedList<Convey.AccountInformation>();


    private Convey.CredentialsMediator local_mediator;
    private Goa.Client? goa_service = null;


    /** Fired when a new account is created. */
    public signal void account_added(Convey.AccountInformation added, Status status);

    /** Fired when an existing account's state has changed. */
    public signal void account_status_changed(Convey.AccountInformation changed,
                                              Status new_status);

    /** Fired when an account is deleted. */
    public signal void account_removed(Convey.AccountInformation removed);

    /** Emitted to notify an account problem has occurred. */
    public signal void report_problem(Convey.ProblemReport problem);


    public Manager(Convey.CredentialsMediator local_mediator,
                   GLib.File config_dir,
                   GLib.File data_dir) {
        this.local_mediator = local_mediator;
        this.config_dir = config_dir;
        this.data_dir = data_dir;
    }

    public async void connect_goa(GLib.Cancellable? cancellable)
        throws GLib.Error {
        var client = yield new Goa.Client(cancellable);
        var manager = (GLib.DBusObjectManagerClient) client.get_object_manager();
        if (manager.name_owner == null) {
            debug("GNOME Online Accounts is not installed");
            return;
        }
        this.goa_service = client;
        this.goa_service.account_added.connect(on_goa_account_added);
        this.goa_service.account_changed.connect(on_goa_account_changed);
        this.goa_service.account_removed.connect(on_goa_account_removed);
    }

    /** Returns the account with the given id. */
    public Convey.AccountInformation? get_account(string id) {
        AccountState? state = this.accounts.get(id);
        return (state != null) ? state.account : null;
    }

    /** Returns the status for the given account. */
    public Status get_status(Convey.AccountInformation account) {
        AccountState? state = this.accounts.get(account.id);
        return (state != null) ? state.status : Status.UNAVAILABLE;
    }

    /** Returns a read-only iterable of all currently known accounts. */
    public Convey.Iterable<Convey.AccountInformation> iterable() {
        return Convey.traverse<AccountState>(
            this.accounts.values
        ).map<Convey.AccountInformation>(
            ((state) => { return state.account; })
        );
    }

    /**
     * Returns the display name for the current desktop login session.
     */
    public string? get_account_name() {
        string? name = Environment.get_real_name();
        if (Convey.String.is_empty(name) || name == "Unknown") {
            name = null;
        }
        return name;
    }

    /**
     * Returns a new account, not yet stored on disk.
     */
    public async Convey.AccountInformation
        new_orphan_account(Convey.ServiceProvider provider,
                           Convey.RFC822.MailboxAddress primary_mailbox,
                           GLib.Cancellable? cancellable) {
        string id = yield next_id(cancellable);
        return new Convey.AccountInformation(
            id, provider, this.local_mediator, primary_mailbox
        );
    }

    /**
     * Creates new account's disk and credential storage as needed.
     */
    public async void create_account(Convey.AccountInformation account,
                                     GLib.Cancellable? cancellable)
        throws GLib.Error {
        yield create_account_dirs(account, cancellable);
        yield save_account(account, cancellable);
        set_enabled(account, true);

        // if it's a local account, save the passwords now
        SecretMediator? mediator = account.mediator as SecretMediator;
        if (mediator != null) {
            yield mediator.update_token(account, account.incoming, cancellable);
            yield mediator.update_token(account, account.outgoing, cancellable);
        }
    }

    public async void load_accounts(GLib.Cancellable? cancellable)
        throws GLib.Error {
        // Step 1. Load existing accounts from the user config dir
        GLib.FileEnumerator? enumerator = null;
        try {
            enumerator = yield this.config_dir.enumerate_children_async(
                "standard::*",
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                cancellable
            );
        } catch (GLib.IOError.NOT_FOUND err) {
            // Don't worry about the dir not being found, it just
            // means we have no accounts to load.
        }

        while (enumerator != null && !cancellable.is_cancelled()) {
            // Get 10 at a time to batch the IO together
            GLib.List<GLib.FileInfo> info_list = yield enumerator.next_files_async(
                10, GLib.Priority.DEFAULT, cancellable
            );

            uint len = info_list.length();
            for (uint i = 0; i < len && !cancellable.is_cancelled(); i++) {
                GLib.FileInfo file = info_list.nth_data(i);
                if (file.get_file_type() == FileType.DIRECTORY) {
                    string id = file.get_name();
                    try {
                        Convey.AccountInformation info = yield load_account(
                            id, cancellable
                        );
                        set_enabled(info, true);
                    } catch (ConfigError.UNAVAILABLE err) {
                        // All good, this was handled properly by
                        // load_account.
                    } catch (ConfigError.REMOVED err) {
                        // All good, this was handled properly by
                        // load_account.
                    } catch (GLib.Error err) {
                        debug("Error loading account %s", id);
                        report_problem(new Convey.ProblemReport(err));
                    }
                }
            }

            if (len == 0) {
                // We're done
                enumerator = null;
            }
        }

        // Step 2. Load previously unseen accounts from GOA, if available.
        if (this.goa_service != null) {
            GLib.List<Goa.Object> list = this.goa_service.get_accounts();
            for (int i=0; i < list.length() && !cancellable.is_cancelled(); i++) {
                Goa.Object account = list.nth_data(i);
                string id = to_convey_id(account);
                if (!this.accounts.has_key(id)) {
                    yield this.create_goa_account(account, cancellable);
                }
            }
        }
    }

    /**
     * Marks an existing account as being unavailable.
     *
     * This keeps the account in the known set, but marks it as being
     * unavailable.
     */
    public void disable_account(Convey.AccountInformation account) {
        if (this.accounts.has_key(account.id)) {
            set_available(account, false);
        }
    }

    /**
     * Removes an account from the manager's set of known accounts.
     *
     * This removes the account from the known set, marks the account
     * as deleted, and queues it for deletion. The account will not
     * actually be deleted until {@link expunge_accounts} is called,
     * and until then the account can be re-added using {@link
     * restore_account}.
     */
    public async void remove_account(Convey.AccountInformation account,
                                     GLib.Cancellable? cancellable)
        throws GLib.Error {
        this.accounts.unset(account.id);
        this.removed.add(account);
        account.changed.disconnect(on_account_changed);
        yield save_account(account, cancellable);
        account_removed(account);
    }

    /**
     * Restores an account that has previously been removed.
     *
     * This restores an account previously removed via a call to
     * {@link remove_account}, adding it back to the known set, as
     * long as {@link expunge_accounts} has not been called since
     * he account was removed.
     */
    public async void restore_account(Convey.AccountInformation account,
                                      GLib.Cancellable? cancellable)
        throws GLib.Error {
        if (this.removed.remove(account)) {
            yield save_account(account, cancellable);
            set_enabled(account, true);
        }
    }

    /**
     * Deletes all local data for all accounts that have been removed.
     */
    public async void expunge_accounts(GLib.Cancellable? cancellable)
        throws GLib.Error {
        while (!this.removed.is_empty && !cancellable.is_cancelled()) {
            yield delete_account(this.removed.remove_at(0), cancellable);
        }
    }

    /**
     * Saves an account's configuration data to disk.
     */
    public async void save_account(Convey.AccountInformation info,
                                   GLib.Cancellable? cancellable)
        throws GLib.Error {
        // Ensure only one async task is saving an info at once, since
        // at least the Engine can cause multiple saves to be called
        // in quick succession when updating special folder config.
        int token = yield info.write_lock.claim_async(cancellable);

        GLib.Error? thrown = null;
        try {
            yield save_account_locked(info, cancellable);
        } catch (GLib.Error err) {
            thrown = err;
        }

        info.write_lock.release(ref token);

        if (thrown != null) {
            throw thrown;
        }
    }

    /** Updates a local account service's credentials. */
    public async void update_local_credentials(Convey.AccountInformation account,
                                               Convey.ServiceInformation old_service,
                                               Convey.ServiceInformation new_service,
                                               GLib.Cancellable? cancellable)
        throws GLib.Error {
        SecretMediator? mediator = account.mediator as SecretMediator;
        if (mediator != null) {
            if (new_service.credentials != null) {
                yield mediator.update_token(account, new_service, cancellable);
            }

            if (old_service.credentials != null &&
                (new_service.credentials == null ||
                 (new_service.credentials != null &&
                  old_service.credentials.user != old_service.credentials.user))) {
                yield mediator.clear_token(account, old_service, cancellable);
            }
        }
    }

    /**
     * Determines if an account is a GOA account or not.
     */
    public bool is_goa_account(Convey.AccountInformation account) {
        return (account.mediator is GoaMediator);
    }

    /** Determines if GNOME Online Accounts is available. */
    public bool is_goa_available {
        get { return this.goa_service != null; }
    }

    /** Returns the GNOME Online Accounts providers usable for mail. */
    internal async Gee.List<Goa.Provider> get_goa_providers()
        throws GLib.Error {
        var providers = new Gee.ArrayList<Goa.Provider>();
        GLib.List<Goa.Provider> all;
        yield Goa.Provider.get_all(out all);
        int branded = 0;
        foreach (Goa.Provider provider in all) {
            Goa.ProviderFeatures features = provider.get_provider_features();
            if (!(Goa.ProviderFeatures.MAIL in features) ||
                provider.get_provider_type() == GOA_NON_IMAP_MAIL_PROVIDER) {
                continue;
            }
            if (Goa.ProviderFeatures.BRANDED in features) {
                providers.insert(branded++, provider);
            } else {
                providers.add(provider);
            }
        }
        return providers;
    }

    /** Shows the GNOME Online Accounts sign-in for the given provider. */
    internal async void add_goa_account(Goa.Provider provider,
                                        Gtk.Widget parent,
                                        GLib.Cancellable? cancellable)
        throws GLib.Error {
        yield provider.add_account(this.goa_service, parent, cancellable);
    }

    /** Shows the GNOME Online Accounts details for the given account. */
    public async void show_goa_account(Convey.AccountInformation account,
                                       Gtk.Widget parent,
                                       GLib.Cancellable? cancellable)
        throws GLib.Error {
        GoaMediator? mediator = account.mediator as GoaMediator;
        Goa.Provider? provider = (mediator == null) ? null :
            Goa.Provider.get_for_provider_type(
                mediator.handle.get_account().provider_type
            );
        if (provider == null) {
            throw new GLib.IOError.NOT_SUPPORTED("Not a GOA Account");
        }
        yield provider.show_account(
            this.goa_service, mediator.handle, parent, cancellable
        );
    }

    /** Returns the next id for a new local account. */
    private async string next_id(GLib.Cancellable? cancellable) {
        // Get the next known free id
        string? last_account = this.accounts.keys.fold<string?>((next, last) => {
                string? result = last;
                if (next.has_prefix(LOCAL_ID_PREFIX)) {
                    result = (last == null || strcmp(last, next) < 0) ? next : last;
                }
                return result;
            },
            null);

        uint next_id = 1;
        if (last_account != null) {
            next_id = int.parse(
                last_account.substring(LOCAL_ID_PREFIX.length)
            ) + 1;
        }

        // Check for existing directories that might conflict
        string id = LOCAL_ID_FORMAT.printf(next_id);
        try {
            while ((yield Convey.Files.query_exists_async(
                        this.config_dir.get_child(id), cancellable)) ||
                   (yield Convey.Files.query_exists_async(
                       this.data_dir.get_child(id), cancellable))) {
                next_id++;
                id = LOCAL_ID_FORMAT.printf(next_id);
            }
        } catch (GLib.Error err) {
            // Not much we can do here except keep going anyway?
            debug("Error checking for a free id on disk: %s", err.message);
        }

        return id;
    }

    /**
     * Loads an account info from a config directory.
     *
     * Throws an error if the config file was not found, could not be
     * parsed, or doesn't have all required fields.
     */
    private async Convey.AccountInformation
        load_account(string id, GLib.Cancellable? cancellable)
        throws ConfigError {
        GLib.File config_dir = this.config_dir.get_child(id);
        GLib.File data_dir = this.data_dir.get_child(id);

        Convey.ConfigFile config = new Convey.ConfigFile(
            config_dir.get_child(SETTINGS_FILENAME)
        );

        try {
            yield config.load(cancellable);
        } catch (GLib.KeyFileError err) {
            throw new ConfigError.SYNTAX(err.message);
        } catch (GLib.Error err) {
            throw new ConfigError.IO(err.message);
        }

        Convey.ConfigFile.Group metadata_config =
            config.get_group(GROUP_METADATA);
        int version = metadata_config.get_int(METADATA_VERSION, 0);
        Status status = Status.ENABLED;
        try {
            status = Status.for_value(
                metadata_config.get_string(
                    METADATA_STATUS, status.to_value()
                ));
        } catch (Convey.EngineError err) {
            throw new ConfigError.SYNTAX("%s: Invalid status value", id);
        }

        string? goa_id = metadata_config.get_string(METADATA_GOA, null);
        bool is_goa = (goa_id != null);

        // This exists purely for people were running mainline with GOA
        // accounts before the new accounts editor landed and 0.13 was
        // released. It can be removed once 3.34 is out.
        if (goa_id == null && id.has_prefix(GOA_ID_PREFIX)) {
            goa_id = to_goa_id(id);
            is_goa = true;
        }

        Goa.Object? goa_handle = null;
        GoaMediator? goa_mediator = null;
        Convey.ServiceProvider? default_provider = null;
        Convey.CredentialsMediator mediator = this.local_mediator;

        if (is_goa) {
            if (this.goa_service == null) {
                throw new ConfigError.MANAGEMENT("GOA service not available");
            }

            goa_handle = this.goa_service.lookup_by_id(goa_id);
            if (goa_handle != null) {
                mediator = goa_mediator = new GoaMediator(goa_handle);
                default_provider = goa_mediator.get_service_provider();
            } else {
                // The GOA account has gone away, so there's nothing
                // we can do except to remove it locally as well
                info(
                    "%s: GOA account %s has been removed, removing local data",
                    id, goa_id
                );
                status = Status.REMOVED;
                // Use the default mediator since we can't create a
                // GOA equiv, but set a dummy default provider so we
                // don't get an error loading the config
                default_provider = Convey.ServiceProvider.OTHER;
            }
        }

        AccountConfig? accounts = null;
        ServiceConfig? services = null;
        switch (version) {
        case 0:
            accounts = new AccountConfigLegacy();
            services = new ServiceConfigLegacy();
            break;

        case 1:
            accounts = new AccountConfigV1(is_goa);
            services = new ServiceConfigV1();
            break;

        default:
            throw new ConfigError.VERSION(
                "Unsupported config version: %d", version
            );
        }

        Convey.AccountInformation? account = null;
        try {
            account = accounts.load(
                config,
                id,
                mediator,
                default_provider,
                get_account_name()
            );
            account.set_account_directories(config_dir, data_dir);
        } catch (GLib.KeyFileError err) {
            throw new ConfigError.SYNTAX(err.message);
        }

        // If the account has been marked as removed, now that we have
        // an account object and its dirs have been set up we can add
        // it to the removed list and just bail out.
        if (status == Status.REMOVED) {
            this.removed.add(account);
            throw new ConfigError.REMOVED("Account marked for removal");
        }

        if (!is_goa) {
            try {
                services.load(config, account, account.incoming);
                services.load(config, account, account.outgoing);
            } catch (GLib.KeyFileError err) {
                throw new ConfigError.SYNTAX(err.message);
            }
        } else {
            account.service_label = goa_mediator.get_service_label();
            account.account_backend = goa_mediator.get_account_backend();
            try {
                yield goa_mediator.update(account, cancellable);
            } catch (GLib.Error err) {
                throw new ConfigError.MANAGEMENT(err.message);
            }

            if (!is_valid_goa_account(goa_handle)) {
                // If we get here, the GOA account's mail service used
                // to exist (we just loaded Convey's config for it) but
                // no longer does. This indicates the mail service has
                // been disabled, so set it as disabled.
                set_available(account, false);
                throw new ConfigError.UNAVAILABLE(
                    "GOA Mail service not available"
                );
            }
        }

        // If the account has been marked as disabled, mark it as such
        // and bail out.
        if (status == Status.DISABLED) {
            set_enabled(account, false);
            throw new ConfigError.UNAVAILABLE("Account disabled");
        }

        return account;
    }

    private async void save_account_locked(Convey.AccountInformation account,
                                           GLib.Cancellable? cancellable)
        throws GLib.Error {
        if (account.config_dir == null) {
            throw new GLib.IOError.NOT_SUPPORTED(
                "Account %s does not have a config directory", account.id
            );
        }

        Convey.ConfigFile config = new Convey.ConfigFile(
            account.config_dir.get_child(SETTINGS_FILENAME)
        );

        // Load the file first so we maintain old settings
        try {
            yield config.load(cancellable);
        } catch (GLib.Error err) {
            // Oh well, just create a new one when saving
            debug("Could not load existing config file: %s", err.message);
        }

        Convey.ConfigFile.Group metadata_config =
            config.get_group(GROUP_METADATA);
        metadata_config.set_int(
            METADATA_VERSION, CONFIG_VERSION
        );
        metadata_config.set_string(
            METADATA_STATUS, get_status(account).to_value()
        );

        bool is_goa = is_goa_account(account);
        if (is_goa) {
            metadata_config.set_string(METADATA_GOA, to_goa_id(account.id));
        }

        AccountConfig accounts = new AccountConfigV1(is_goa);
        accounts.save(account, config);

        if (!is_goa) {
            ServiceConfig services = new ServiceConfigV1();
            services.save(account, account.incoming, config);
            services.save(account, account.outgoing, config);
        }

        debug("Writing config to: %s", config.file.get_path());
        yield config.save(cancellable);
    }

    private async void delete_account(Convey.AccountInformation info,
                                      GLib.Cancellable? cancellable)
        throws GLib.Error {
        // If it's a local account, try clearing the passwords. Keep
        // going if there's an error though since we really want to
        // delete the account dirs.
        SecretMediator? mediator = info.mediator as SecretMediator;
        if (mediator != null) {
            try {
                yield mediator.clear_token(info, info.incoming, cancellable);
            } catch (Error e) {
                debug("Error clearing IMAP password: %s", e.message);
            }

            try {
                yield mediator.clear_token(info, info.outgoing, cancellable);
            } catch (Error e) {
                debug("Error clearing IMAP password: %s", e.message);
            }
        }

        if (info.data_dir != null) {
            yield Convey.Files.recursive_delete_async(
                info.data_dir, GLib.Priority.LOW, cancellable
            );
        }

        // Delete config last so if there are any errors above, it
        // will be re-tried at next startup.
        if (info.config_dir != null) {
            yield Convey.Files.recursive_delete_async(
                info.config_dir, GLib.Priority.LOW, cancellable
            );
        }
    }

    private inline AccountState lookup_state(Convey.AccountInformation account) {
        AccountState? state = this.accounts.get(account.id);
        if (state == null) {
            state = new AccountState(account);
            this.accounts.set(account.id, state);
        }
        return state;
    }

    private bool set_enabled(Convey.AccountInformation account, bool is_enabled) {
        bool was_added = !this.accounts.has_key(account.id);
        AccountState state = lookup_state(account);
        Status existing_status = state.status;
        state.enabled = is_enabled;

        bool ret = false;
        if (was_added) {
            account_added(state.account, state.status);
            account.changed.connect(on_account_changed);
            ret = true;
        } else if (state.status != existing_status) {
            account_status_changed(state.account, state.status);
            ret = true;
        }
        return ret;
    }

    private bool set_available(Convey.AccountInformation account, bool is_available) {
        bool was_added = !this.accounts.has_key(account.id);
        AccountState state = lookup_state(account);
        Status existing_status = state.status;
        state.available = is_available;

        bool ret = false;
        if (was_added) {
            account_added(state.account, state.status);
            account.changed.connect(on_account_changed);
            ret = true;
        } else if (state.status != existing_status) {
            account_status_changed(state.account, state.status);
            ret = true;
        }
        return ret;
    }

    private async void create_account_dirs(Convey.AccountInformation info,
                                          Cancellable? cancellable)
        throws GLib.Error {
        GLib.File config = this.config_dir.get_child(info.id);
        GLib.File data = this.data_dir.get_child(info.id);

        yield Convey.Files.make_directory_with_parents(config, cancellable);
        yield Convey.Files.make_directory_with_parents(data, cancellable);

        info.set_account_directories(config, data);
    }

    private inline string to_convey_id(Goa.Object account) {
        return GOA_ID_PREFIX + account.get_account().id;
    }

    private inline string to_goa_id(string id) {
        return id.has_prefix(GOA_ID_PREFIX)
            ? id.substring(GOA_ID_PREFIX.length)
            : id;
    }

    private bool is_valid_goa_account(Goa.Object handle) {
        Goa.Account account = handle.get_account();
        Goa.Mail? mail = handle.get_mail();
        bool is_microsoft = (
            account.provider_type == "ms_graph" ||
            account.provider_type == "windows_live"
        );
        bool has_auth = (
            handle.get_oauth2_based() != null ||
            handle.get_password_based() != null
        );
        bool has_identity = !Convey.String.is_empty_or_whitespace(
            account.presentation_identity
        );
        if (mail != null) {
            bool has_mail_endpoints = (
                !Convey.String.is_empty(mail.imap_host) &&
                !Convey.String.is_empty(mail.smtp_host)
            );
            if (has_mail_endpoints) {
                return (
                    !account.mail_disabled &&
                    has_identity
                );
            }
            return (
                is_microsoft &&
                !account.mail_disabled &&
                has_auth &&
                has_identity
            );
        }
        return (
            is_microsoft &&
            !account.mail_disabled &&
            has_auth &&
            has_identity
        );
    }

    private async void create_goa_account(Goa.Object account,
                                          GLib.Cancellable? cancellable) {
        if (is_valid_goa_account(account)) {
            Goa.Account goa_account = account.get_account();
            Goa.Mail? mail = account.get_mail();
            string mailbox = (
                mail != null
                ? mail.email_address
                : goa_account.presentation_identity
            );
            if (Convey.String.is_empty_or_whitespace(mailbox)) {
                debug(
                    "Ignoring GOA %s account %s, mailbox identity missing",
                    goa_account.provider_type,
                    goa_account.id
                );
                return;
            }
            string? name = (mail != null) ? mail.name : null;
            if (Convey.String.is_empty_or_whitespace(name)) {
                name = get_account_name();
            }

            GoaMediator mediator = new GoaMediator(account);
            Convey.AccountInformation info = new Convey.AccountInformation(
                to_convey_id(account),
                mediator.get_service_provider(),
                mediator,
                new Convey.RFC822.MailboxAddress(name, mailbox)
            );

            info.account_backend = mediator.get_account_backend();
            info.ordinal = Convey.AccountInformation.next_ordinal++;
            info.service_label = mediator.get_service_label();
            info.label = goa_account.presentation_identity;

            try {
                yield create_account_dirs(info, cancellable);
                yield save_account(info, cancellable);
                yield mediator.update(info, cancellable);
            } catch (GLib.Error err) {
                report_problem(new Convey.ProblemReport(err));
            }

            set_enabled(info, true);
        } else {
            debug(
                "Ignoring GOA %s account %s, mail service not usable",
                account.get_account().provider_type,
                account.get_account().id
            );
        }
    }

    private async void update_goa_account(Convey.AccountInformation account,
                                          bool is_available,
                                          GLib.Cancellable? cancellable) {
        GoaMediator mediator = (GoaMediator) account.mediator;
        try {
            yield mediator.update(account, cancellable);
            account.account_backend = mediator.get_account_backend();

            if (is_available) {
                // Update will clear the creds, so make sure they get
                // refreshed
                yield account.load_outgoing_credentials(cancellable);
                yield account.load_incoming_credentials(cancellable);
            }
        } catch (GLib.Error err) {
            report_problem(new Convey.AccountProblemReport(account, err));
        }

        set_available(account, is_available);
    }


    private void on_goa_account_added(Goa.Object account) {
        debug("GOA account added: %s", account.get_account().id);
        // No cancellable: driven by external GOA events, not tied
        // to any user-cancellable operation
        on_goa_account_changed(account);
    }

    private void on_goa_account_changed(Goa.Object account) {
        debug("GOA account changed: %s", account.get_account().id);
        AccountState? state = this.accounts.get(to_convey_id(account));
        // No cancellable, as per on_goa_account_added
        if (state != null) {
            ((GoaMediator) state.account.mediator).handle = account;
            // We already know about this account, so check that it is
            // still valid. If not, the account should be disabled,
            // not deleted, since it may be re-enabled at some point.
            this.update_goa_account.begin(
                state.account,
                is_valid_goa_account(account),
                null
            );
        } else {
            // We haven't created an account for this GOA account
            // before, so try doing so now.
            this.create_goa_account.begin(account, null);
        }
    }

    private void on_goa_account_removed(Goa.Object account) {
        debug("GOA account removed: %s", account.get_account().id);
        AccountState? state = this.accounts.get(to_convey_id(account));
        if (state != null) {
            // Just disabled it for now in case the GOA daemon as just
            // shutting down.
            set_available(state.account, false);
        }
    }

    private void on_account_changed(Convey.AccountInformation account) {
        this.save_account.begin(
            account, null,
            (obj, res) => {
                try {
                    this.save_account.end(res);
                } catch (GLib.Error err) {
                    report_problem(new Convey.AccountProblemReport(account, err));
                }
            }
        );
    }

}

/** Objects that can be used to load/save account configuration. */
public interface Accounts.AccountConfig : GLib.Object {

    /** Loads a supported account from a config file. */
    public abstract Convey.AccountInformation
        load(Convey.ConfigFile config,
             string id,
             Convey.CredentialsMediator mediator,
             Convey.ServiceProvider? default_provider,
             string? default_name)
        throws ConfigError, GLib.KeyFileError;

    /** Saves an account to a config file. */
    public abstract void save(Convey.AccountInformation account,
                              Convey.ConfigFile config);

}


/** Objects that can be used to load/save service configuration. */
public interface Accounts.ServiceConfig : GLib.Object {

    /** Loads a service from a config file. */
    public abstract void load(Convey.ConfigFile config,
                              Convey.AccountInformation account,
                              Convey.ServiceInformation service)
        throws ConfigError, GLib.KeyFileError;

    /** Saves a service to a config file. */
    public abstract void save(Convey.AccountInformation account,
                              Convey.ServiceInformation service,
                              Convey.ConfigFile config);

}


public errordomain Accounts.ConfigError {
    IO,
    MANAGEMENT,
    SYNTAX,
    VERSION,
    UNAVAILABLE,
    REMOVED;
}


/**
 * Manages persistence for version 1 config files.
 */
public class Accounts.AccountConfigV1 : AccountConfig, GLib.Object {


    private const string GROUP_ACCOUNT = "Account";
    private const string GROUP_FOLDERS = "Folders";

    private const string ACCOUNT_ARCHIVE_INSTEAD_OF_TRASH = "archive_instead_of_trash";
    private const string ACCOUNT_LABEL = "label";
    private const string ACCOUNT_ORDINAL = "ordinal";
    private const string ACCOUNT_PREFETCH = "prefetch_days";
    private const string ACCOUNT_PROVIDER = "service_provider";
    private const string ACCOUNT_SAVE_DRAFTS = "save_drafts";
    private const string ACCOUNT_SAVE_SENT = "save_sent";
    private const string ACCOUNT_SENDERS = "sender_mailboxes";
    private const string ACCOUNT_SENDER_SIGS = "sender_signatures";
    private const string ACCOUNT_SIG = "signature";
    private const string ACCOUNT_USE_SIG = "use_signature";

    private const string FOLDER_ARCHIVE = "archive_folder";
    private const string FOLDER_DRAFTS = "drafts_folder";
    private const string FOLDER_JUNK = "junk_folder";
    private const string FOLDER_SENT = "sent_folder";
    private const string FOLDER_SPAM = "spam_folder";
    private const string FOLDER_TRASH = "trash_folder";


    private bool is_managed;

    public AccountConfigV1(bool is_managed) {
        this.is_managed = is_managed;
    }

    public  Convey.AccountInformation load(Convey.ConfigFile config,
                                          string id,
                                          Convey.CredentialsMediator mediator,
                                          Convey.ServiceProvider? default_provider,
                                          string? default_name)
        throws ConfigError, GLib.KeyFileError {
        Convey.ConfigFile.Group account_config =
            config.get_group(GROUP_ACCOUNT);

        Gee.List<Convey.RFC822.MailboxAddress> senders =
            new Gee.LinkedList<Convey.RFC822.MailboxAddress>();
        foreach (string sender in
                 account_config.get_required_string_list(ACCOUNT_SENDERS)) {
            try {
                senders.add(
                    new Convey.RFC822.MailboxAddress.from_rfc822_string(sender)
                );
            } catch (Convey.RFC822.Error err) {
                throw new ConfigError.SYNTAX(
                    "%s: Invalid sender address: %s", id, sender
                );
            }
        }

        if (senders.is_empty) {
            throw new ConfigError.SYNTAX("%s: No sender addresses found", id);
        }

        Convey.ServiceProvider provider = (
            default_provider != null
            ? default_provider
            : account_config.parse_required_value<Convey.ServiceProvider>(
                ACCOUNT_PROVIDER,
                (value) => {
                    try {
                        return Convey.ServiceProvider.for_value(value);
                    } catch (Convey.EngineError err) {
                        throw new GLib.KeyFileError.INVALID_VALUE(err.message);
                    }
                }
            )
        );

        Convey.AccountInformation account = new Convey.AccountInformation(
            id, provider, mediator, senders.remove_at(0)
        );

        account.ordinal = account_config.get_int(
            ACCOUNT_ORDINAL, Convey.AccountInformation.next_ordinal++
        );
        account.label = account_config.get_string(
            ACCOUNT_LABEL, account.label
        );
        account.prefetch_period_days = account_config.get_int(
            ACCOUNT_PREFETCH, account.prefetch_period_days
        );
        account.save_drafts = account_config.get_bool(
            ACCOUNT_SAVE_DRAFTS, account.save_drafts
        );
        account.save_sent = account_config.get_bool(
            ACCOUNT_SAVE_SENT, account.save_sent
        );
        account.archive_instead_of_trash = account_config.get_bool(
            ACCOUNT_ARCHIVE_INSTEAD_OF_TRASH, account.archive_instead_of_trash
        );
        account.use_signature = account_config.get_bool(
            ACCOUNT_USE_SIG, account.use_signature
        );
        account.signature = account_config.get_string(
            ACCOUNT_SIG, account.signature
        );
        foreach (Convey.RFC822.MailboxAddress sender in senders) {
            account.append_sender(sender);
        }
        Gee.List<string> sender_sigs =
            account_config.get_string_list(ACCOUNT_SENDER_SIGS);
        for (int i = 0;
             i < sender_sigs.size && i < account.sender_mailboxes.size;
             i++) {
            account.set_sender_signature(
                account.sender_mailboxes[i], sender_sigs[i]
            );
        }

        Convey.ConfigFile.Group folder_config =
            config.get_group(GROUP_FOLDERS);
        account.set_folder_steps_for_use(
            ARCHIVE, folder_config.get_string_list(FOLDER_ARCHIVE)
        );
        account.set_folder_steps_for_use(
            DRAFTS, folder_config.get_string_list(FOLDER_DRAFTS)
        );
        account.set_folder_steps_for_use(
            SENT, folder_config.get_string_list(FOLDER_SENT)
        );
        // v3.32-3.36 used spam instead of junk
        if (folder_config.has_key(FOLDER_SPAM)) {
            account.set_folder_steps_for_use(
                JUNK, folder_config.get_string_list(FOLDER_SPAM)
            );
        }
        if (folder_config.has_key(FOLDER_JUNK)) {
            account.set_folder_steps_for_use(
                JUNK, folder_config.get_string_list(FOLDER_JUNK)
            );
        }
        account.set_folder_steps_for_use(
            TRASH, folder_config.get_string_list(FOLDER_TRASH)
        );

        return account;
    }

    /** Saves an account to a config file. */
    public void save(Convey.AccountInformation account,
                     Convey.ConfigFile config) {
        Convey.ConfigFile.Group account_config =
            config.get_group(GROUP_ACCOUNT);
        account_config.set_int(ACCOUNT_ORDINAL, account.ordinal);
        account_config.set_string(ACCOUNT_LABEL, account.label);
        account_config.set_int(ACCOUNT_PREFETCH, account.prefetch_period_days);
        account_config.set_bool(ACCOUNT_SAVE_DRAFTS, account.save_drafts);
        account_config.set_bool(ACCOUNT_SAVE_SENT, account.save_sent);
        account_config.set_bool(
            ACCOUNT_ARCHIVE_INSTEAD_OF_TRASH, account.archive_instead_of_trash
        );
        account_config.set_bool(ACCOUNT_USE_SIG, account.use_signature);
        account_config.set_string(ACCOUNT_SIG, account.signature);
        account_config.set_string_list(
            ACCOUNT_SENDERS,
            Convey.traverse(account.sender_mailboxes)
            .map<string>((sender) => sender.to_rfc822_string())
            .to_array_list()
        );
        account_config.set_string_list(
            ACCOUNT_SENDER_SIGS,
            Convey.traverse(account.sender_mailboxes)
            .map<string>((sender) => account.get_sender_signature(sender))
            .to_array_list()
        );

        if (!is_managed) {
            account_config.set_string(
                ACCOUNT_PROVIDER, account.service_provider.to_value()
            );
        }

        Convey.ConfigFile.Group folder_config =
            config.get_group(GROUP_FOLDERS);
        save_folder(
            folder_config,
            FOLDER_ARCHIVE,
            account.get_folder_steps_for_use(ARCHIVE)
        );
        save_folder(
            folder_config,
            FOLDER_DRAFTS,
            account.get_folder_steps_for_use(DRAFTS)
        );
        save_folder(
            folder_config,
            FOLDER_SENT,
            account.get_folder_steps_for_use(SENT)
        );
        save_folder(
            folder_config,
            FOLDER_JUNK,
            account.get_folder_steps_for_use(JUNK)
        );
        save_folder(
            folder_config,
            FOLDER_TRASH,
            account.get_folder_steps_for_use(TRASH)
        );
    }

    private inline void save_folder(Convey.ConfigFile.Group config,
                                    string key,
                                    Gee.List<string>? steps) {
        if (steps != null) {
            config.set_string_list(key, steps);
        }
    }

}


/**
 * Manages persistence for un-versioned account configuration.
 */
public class Accounts.AccountConfigLegacy : AccountConfig, GLib.Object {

    internal const string GROUP = "AccountInformation";

    private const string ALTERNATE_EMAILS_KEY = "alternate_emails";
    private const string ARCHIVE_FOLDER_KEY = "archive_folder";
    private const string CREDENTIALS_METHOD_KEY = "credentials_method";
    private const string CREDENTIALS_PROVIDER_KEY = "credentials_provider";
    private const string DRAFTS_FOLDER_KEY = "drafts_folder";
    private const string EMAIL_SIGNATURE_KEY = "email_signature";
    private const string NICKNAME_KEY = "nickname";
    private const string ORDINAL_KEY = "ordinal";
    private const string PREFETCH_PERIOD_DAYS_KEY = "prefetch_period_days";
    private const string PRIMARY_EMAIL_KEY = "primary_email";
    private const string REAL_NAME_KEY = "real_name";
    private const string SAVE_DRAFTS_KEY = "save_drafts";
    private const string SAVE_SENT_MAIL_KEY = "save_sent_mail";
    private const string SENT_MAIL_FOLDER_KEY = "sent_mail_folder";
    private const string SERVICE_PROVIDER_KEY = "service_provider";
    private const string SPAM_FOLDER_KEY = "spam_folder";
    private const string TRASH_FOLDER_KEY = "trash_folder";
    private const string USE_EMAIL_SIGNATURE_KEY = "use_email_signature";


    public Convey.AccountInformation load(Convey.ConfigFile config_file,
                                         string id,
                                         Convey.CredentialsMediator mediator,
                                         Convey.ServiceProvider? default_provider,
                                         string? default_name)
        throws ConfigError, GLib.KeyFileError {
        Convey.ConfigFile.Group config = config_file.get_group(GROUP);

        string primary_email = config.get_required_string(PRIMARY_EMAIL_KEY);
        string real_name = config.get_string(REAL_NAME_KEY, default_name);

        Convey.ServiceProvider provider = (
            default_provider != null
            ? default_provider
            : config.parse_required_value<Convey.ServiceProvider>(
                SERVICE_PROVIDER_KEY,
                (value) => {
                    try {
                        return Convey.ServiceProvider.for_value(value);
                    } catch (Convey.EngineError err) {
                        throw new GLib.KeyFileError.INVALID_VALUE(err.message);
                    }
                }
            )
        );

        Convey.AccountInformation info = new Convey.AccountInformation(
            id, provider, mediator,
            new Convey.RFC822.MailboxAddress(real_name, primary_email)
        );

        info.ordinal = config.get_int(ORDINAL_KEY, info.ordinal);
        if (info.ordinal >= Convey.AccountInformation.next_ordinal) {
            Convey.AccountInformation.next_ordinal = info.ordinal + 1;
        }

        info.append_sender(new Convey.RFC822.MailboxAddress(
            config.get_string(REAL_NAME_KEY), primary_email
        ));

        info.label = config.get_string(NICKNAME_KEY);

        // Store alternate emails in a list of case-insensitive strings
        Gee.List<string> alt_email_list = config.get_string_list(
            ALTERNATE_EMAILS_KEY
        );
        foreach (string alt_email in alt_email_list) {
            try {
                var mailboxes = new Convey.RFC822.MailboxAddresses.from_rfc822_string(alt_email);
                foreach (Convey.RFC822.MailboxAddress mailbox in mailboxes.get_all()) {
                    info.append_sender(mailbox);
                }
            } catch (Convey.RFC822.Error error) {
                throw new ConfigError.SYNTAX(
                    "Invalid alternate email: %s", error.message
                );
            }
        }

        info.prefetch_period_days = config.get_int(
            PREFETCH_PERIOD_DAYS_KEY, info.prefetch_period_days
        );
        info.save_sent = config.get_bool(
            SAVE_SENT_MAIL_KEY, info.save_sent
        );
        info.use_signature = config.get_bool(
            USE_EMAIL_SIGNATURE_KEY, info.use_signature
        );
        info.signature = config.get_string(
            EMAIL_SIGNATURE_KEY, info.signature
        );

        info.set_folder_steps_for_use(
            DRAFTS, config.get_string_list(DRAFTS_FOLDER_KEY)
        );
        info.set_folder_steps_for_use(
            SENT, config.get_string_list(SENT_MAIL_FOLDER_KEY)
        );
        info.set_folder_steps_for_use(
            JUNK, config.get_string_list(SPAM_FOLDER_KEY)
        );
        info.set_folder_steps_for_use(
            TRASH, config.get_string_list(TRASH_FOLDER_KEY)
        );
        info.set_folder_steps_for_use(
            ARCHIVE, config.get_string_list(ARCHIVE_FOLDER_KEY)
        );

        info.save_drafts = config.get_bool(SAVE_DRAFTS_KEY, true);

        return info;
    }

    public void save(Convey.AccountInformation info,
                     Convey.ConfigFile config_file) {

        Convey.ConfigFile.Group config = config_file.get_group(GROUP);

        config.set_string(REAL_NAME_KEY, info.primary_mailbox.name ?? "");
        config.set_string(PRIMARY_EMAIL_KEY, info.primary_mailbox.address);
        config.set_string(NICKNAME_KEY, info.label);
        config.set_string(SERVICE_PROVIDER_KEY, info.service_provider.to_value());
        config.set_int(ORDINAL_KEY, info.ordinal);
        config.set_int(PREFETCH_PERIOD_DAYS_KEY, info.prefetch_period_days);
        config.set_bool(SAVE_SENT_MAIL_KEY, info.save_sent);
        config.set_bool(USE_EMAIL_SIGNATURE_KEY, info.use_signature);
        config.set_string(EMAIL_SIGNATURE_KEY, info.signature);
        if (info.has_sender_aliases) {
            Gee.List<Convey.RFC822.MailboxAddress> alts = info.sender_mailboxes;
            // Don't include the primary in the list
            alts.remove_at(0);

            config.set_string_list(
                ALTERNATE_EMAILS_KEY,
                Convey.traverse(alts)
                .map<string>((alt) => alt.to_rfc822_string())
                .to_array_list()
            );
        }

        Gee.List<string> empty = new Gee.ArrayList<string>();
        Gee.List<string>? steps = null;

        steps = info.get_folder_steps_for_use(DRAFTS);
        config.set_string_list(
            DRAFTS_FOLDER_KEY,
            steps != null ? steps : empty
        );

        steps = info.get_folder_steps_for_use(SENT);
        config.set_string_list(
            SENT_MAIL_FOLDER_KEY,
            steps != null ? steps : empty
        );
        steps = info.get_folder_steps_for_use(JUNK);
        config.set_string_list(
            SPAM_FOLDER_KEY,
            steps != null ? steps : empty
        );
        steps = info.get_folder_steps_for_use(TRASH);
        config.set_string_list(
            TRASH_FOLDER_KEY,
            steps != null ? steps : empty
        );
        steps = info.get_folder_steps_for_use(ARCHIVE);
        config.set_string_list(
            ARCHIVE_FOLDER_KEY,
            steps != null ? steps : empty
        );

        config.set_bool(SAVE_DRAFTS_KEY, info.save_drafts);
    }

}


/**
 * Manages persistence for version 1 service configuration.
 */
public class Accounts.ServiceConfigV1 : ServiceConfig, GLib.Object {

    private const string GROUP_INCOMING = "Incoming";
    private const string GROUP_OUTGOING = "Outgoing";

    private const string CREDENTIALS = "credentials";
    private const string HOST = "host";
    private const string LOGIN = "login";
    private const string PORT = "port";
    private const string REMEMBER_PASSWORD = "remember_password";
    private const string SECURITY = "transport_security";


    /** Loads a supported service from a config file. */
    public void load(Convey.ConfigFile config,
                     Convey.AccountInformation account,
                     Convey.ServiceInformation service)
        throws ConfigError, GLib.KeyFileError {
        Convey.ConfigFile.Group service_config = config.get_group(
            service.protocol == IMAP ? GROUP_INCOMING : GROUP_OUTGOING
        );

        string? login = service_config.get_string(LOGIN, null);
        if (login != null) {
            service.credentials = new Convey.Credentials(
                Convey.Credentials.Method.PASSWORD, login
            );
        }
        service.remember_password = service_config.get_bool(
            REMEMBER_PASSWORD, service.remember_password
        );


        if (account.service_provider == Convey.ServiceProvider.OTHER) {
            service.host = service_config.get_required_string(HOST);
            service.port = (uint16) service_config.get_int(PORT, service.port);

            service.transport_security = service_config.parse_required_value
            <Convey.TlsNegotiationMethod>(
                SECURITY,
                (value) => {
                    try {
                        return Convey.TlsNegotiationMethod.for_value(value);
                    } catch (GLib.Error err) {
                        throw new GLib.KeyFileError.INVALID_VALUE(err.message);
                    }
                }
            );

            service.credentials_requirement = service_config.parse_required_value
            <Convey.Credentials.Requirement>(
                CREDENTIALS,
                (value) => {
                    try {
                        return Convey.Credentials.Requirement.for_value(value);
                    } catch (GLib.Error err) {
                        throw new GLib.KeyFileError.INVALID_VALUE(err.message);
                    }
                }
            );

            if (service.port == 0) {
                service.port = service.get_default_port();
            }
        }
    }

    /** Saves an service to a config file. */
    public void save(Convey.AccountInformation account,
                     Convey.ServiceInformation service,
                     Convey.ConfigFile config) {
        Convey.ConfigFile.Group service_config = config.get_group(
            service.protocol == IMAP ? GROUP_INCOMING : GROUP_OUTGOING
        );

        if (service.credentials != null) {
            service_config.set_string(LOGIN, service.credentials.user);
        }
        service_config.set_bool(REMEMBER_PASSWORD, service.remember_password);

        if (account.service_provider == Convey.ServiceProvider.OTHER) {
            service_config.set_string(HOST, service.host);
            service_config.set_int(PORT, service.port);
            service_config.set_string(
                SECURITY, service.transport_security.to_value()
            );

            service_config.set_string(
                CREDENTIALS, service.credentials_requirement.to_value()
            );
        }
    }

}


/**
 * Manages persistence for un-versioned service configuration.
 */
public class Accounts.ServiceConfigLegacy : ServiceConfig, GLib.Object {


    private const string HOST = "host";
    private const string PORT = "port";
    private const string REMEMBER_PASSWORD = "remember_password";
    private const string SSL = "ssl";
    private const string STARTTLS = "starttls";
    private const string USERNAME = "username";

    private const string SMTP_NOAUTH = "smtp_noauth";
    private const string SMTP_USE_IMAP_CREDENTIALS = "smtp_use_imap_credentials";


    /** Loads a supported service from a config file. */
    public void load(Convey.ConfigFile config,
                     Convey.AccountInformation account,
                     Convey.ServiceInformation service)
        throws ConfigError, GLib.KeyFileError {
        Convey.ConfigFile.Group service_config =
            config.get_group(AccountConfigLegacy.GROUP);

        string prefix = service.protocol == Convey.Protocol.IMAP
            ? "imap_" :  "smtp_";

        string? login = service_config.get_string(
            prefix + USERNAME, account.primary_mailbox.address
        );
        if (login != null) {
            service.credentials = new Convey.Credentials(
                Convey.Credentials.Method.PASSWORD, login
            );
        }
        service.remember_password = service_config.get_bool(
            prefix + REMEMBER_PASSWORD, service.remember_password
        );

        if (account.service_provider == Convey.ServiceProvider.OTHER) {
            service.host = service_config.get_string(prefix + HOST, service.host);
            service.port = (uint16) service_config.get_int(
                prefix + PORT, service.port
            );

            bool use_tls = service_config.get_bool(
                prefix + SSL, service.protocol == Convey.Protocol.IMAP
            );
            bool use_starttls = service_config.get_bool(
                prefix + STARTTLS, true
            );
            if (use_tls) {
                service.transport_security = Convey.TlsNegotiationMethod.TRANSPORT;
            } else if (use_starttls) {
                service.transport_security = Convey.TlsNegotiationMethod.START_TLS;
            } else {
                service.transport_security = Convey.TlsNegotiationMethod.NONE;
            }

            if (service.protocol == Convey.Protocol.SMTP) {
                bool use_imap = service_config.get_bool(
                    SMTP_USE_IMAP_CREDENTIALS, service.credentials != null
                );
                bool no_auth = service_config.get_bool(
                    SMTP_NOAUTH, false
                );
                if (use_imap) {
                    service.credentials_requirement =
                        Convey.Credentials.Requirement.USE_INCOMING;
                } else if (!no_auth) {
                    service.credentials_requirement =
                        Convey.Credentials.Requirement.CUSTOM;
                } else {
                    service.credentials_requirement =
                        Convey.Credentials.Requirement.NONE;
                }
            }
        }
    }

    /** Saves an service to a config file. */
    public void save(Convey.AccountInformation account,
                     Convey.ServiceInformation service,
                     Convey.ConfigFile config) {
        Convey.ConfigFile.Group service_config =
            config.get_group(AccountConfigLegacy.GROUP);

        string prefix = service.protocol.to_value().ascii_down() + "_";

        if (service.credentials != null) {
            service_config.set_string(
                prefix + USERNAME, service.credentials.user
            );
        }
        service_config.set_bool(
            prefix + REMEMBER_PASSWORD, service.remember_password
        );

        if (account.service_provider == Convey.ServiceProvider.OTHER) {
            service_config.set_string(prefix + HOST, service.host);
            service_config.set_int(prefix + PORT, service.port);

            switch (service.transport_security) {
            case NONE:
                service_config.set_bool(prefix + SSL, false);
                service_config.set_bool(prefix + STARTTLS, false);
                break;

            case START_TLS:
                service_config.set_bool(prefix + SSL, false);
                service_config.set_bool(prefix + STARTTLS, true);
                break;

            case TRANSPORT:
                service_config.set_bool(prefix + SSL, true);
                service_config.set_bool(prefix + STARTTLS, false);
                break;
            }

            if (service.protocol == Convey.Protocol.SMTP) {
                switch (service.credentials_requirement) {
                case NONE:
                    service_config.set_bool(SMTP_USE_IMAP_CREDENTIALS, false);
                    service_config.set_bool(SMTP_NOAUTH, true);
                    break;

                case USE_INCOMING:
                    service_config.set_bool(SMTP_USE_IMAP_CREDENTIALS, true);
                    service_config.set_bool(SMTP_NOAUTH, false);
                    break;

                case CUSTOM:
                    service_config.set_bool(SMTP_USE_IMAP_CREDENTIALS, false);
                    service_config.set_bool(SMTP_NOAUTH, false);
                    break;
                }
            }
        }
    }

}
