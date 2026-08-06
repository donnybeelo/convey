/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

[CCode (cname = "convey_credman_store")]
private extern bool credman_store(string target, string user, string password)
    throws GLib.Error;

[CCode (cname = "convey_credman_lookup")]
private extern string? credman_lookup(string target) throws GLib.Error;

[CCode (cname = "convey_credman_clear")]
private extern bool credman_clear(string target) throws GLib.Error;


/**
 * Windows implementation of the client's credentials mediator.
 *
 * Stores service passwords in the Windows Credential Manager, which is
 * the platform's equivalent of the Secret Service that
 * secret-mediator.vala talks to on Linux. Meson selects exactly one of
 * the two at build time, and both declare this same class, so callers do
 * not care which is in use. See `secret_mediator_sources` in
 * src/client/meson.build.
 *
 * Credentials are stored as generic credentials under a target name
 * derived from the protocol, host and login, so a single account with
 * separate incoming and outgoing passwords keeps them apart. That
 * mirrors the attribute set the libsecret implementation keys on, which
 * matters because the service forms part of a credential's identity.
 *
 * There is no equivalent of libsecret's locked-keyring handling: the
 * credential store is unlocked with the user's session, so there is
 * nothing to unlock or prompt for. Nor is there any migration of
 * passwords from older Convey releases, since no Windows release
 * predates this one.
 */
public class SecretMediator : Convey.CredentialsMediator, GLib.Object {


    private const string TARGET_PREFIX = "Convey";


    public async SecretMediator(Application.Client application,
                                GLib.Cancellable? cancellable)
        throws GLib.Error {
        // The credential store needs no preparation.
    }

    public virtual async bool load_token(Convey.AccountInformation account,
                                         Convey.ServiceInformation service,
                                         GLib.Cancellable? cancellable)
        throws GLib.Error {
        bool loaded = false;
        if (service.credentials != null) {
            if (service.remember_password) {
                string? password = credman_lookup(to_target(service));
                if (password != null) {
                    service.credentials =
                        service.credentials.copy_with_token(password);
                    loaded = true;
                }
            } else {
                // Not remembering the password, so just make sure it
                // has been filled in
                loaded = service.credentials.is_complete();
            }
        }
        return loaded;
    }

    public async void update_token(Convey.AccountInformation account,
                                   Convey.ServiceInformation service,
                                   GLib.Cancellable? cancellable)
        throws GLib.Error {
        if (service.credentials != null && service.credentials.token != null) {
            credman_store(
                to_target(service),
                service.credentials.user,
                service.credentials.token
            );
        }
    }

    public async void clear_token(Convey.AccountInformation account,
                                  Convey.ServiceInformation service,
                                  GLib.Cancellable? cancellable)
        throws GLib.Error {
        if (service.credentials != null) {
            credman_clear(to_target(service));
        }
    }

    /**
     * Returns the credential store key for a service.
     *
     * Keyed on the same three values the libsecret implementation uses
     * as attributes, so that the incoming and outgoing services of one
     * account do not collide.
     */
    private inline string to_target(Convey.ServiceInformation service) {
        return "%s:%s:%s:%s".printf(
            TARGET_PREFIX,
            service.protocol.to_value().ascii_up(),
            service.host,
            service.credentials.user
        );
    }

}
