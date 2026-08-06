/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Stand-in for the parts of gcr and gck that the client uses.
 *
 * gcr and gck are the GNOME crypto UI and PKCS#11 libraries. The client
 * uses them for one job: recording that the user chose to trust a TLS
 * certificate a server presented, so they are not asked again. This file
 * is compiled //only// where those libraries are unavailable, so that
 * {@link Application.CertificateManager} builds unmodified, and is never
 * compiled alongside them. See `have_gcr` in meson.build.
 *
 * Reporting no trust store here is not a security relaxation: {@link
 * Application.CertificateManager} already handles its absence, since a
 * Linux system without a PKCS#11 trust store behaves the same way. It
 * falls back to its own pinned-certificate database, so a certificate
 * the user accepts is still remembered, just not shared with the rest of
 * the desktop. Certificates are still validated by GIO either way, and
 * an untrusted one still prompts.
 *
 * The native equivalents worth wiring up later are the Windows
 * certificate store and the macOS keychain.
 */

namespace Gck {

    /** A PKCS#11 slot, holding a token. */
    public class Slot : GLib.Object {

    }

}

namespace Gcr {

    /** A certificate held in memory. */
    public class SimpleCertificate : GLib.Object {

        public SimpleCertificate(uint8[] data) {
        }

    }

    /** Initialises the PKCS#11 modules. Never succeeds here. */
    public async bool pkcs11_initialize_async(GLib.Cancellable? cancellable)
        throws GLib.Error {
        return false;
    }

    /** Returns the URI of the trust store, if any. */
    public unowned string? pkcs11_get_trust_store_uri() {
        return null;
    }

    /** Returns the URIs consulted when looking up trust. */
    public unowned string[] pkcs11_get_trust_lookup_uris() {
        return {};
    }

    /** Returns the slot holding the trust store, if any. */
    public Gck.Slot? pkcs11_get_trust_store_slot() {
        return null;
    }

    /** Records that a certificate is trusted for a peer. */
    public async bool trust_add_pinned_certificate_async(
        Gcr.SimpleCertificate certificate,
        string purpose,
        string peer,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
        return false;
    }

    /** Determines if a certificate has been pinned for a peer. */
    public bool trust_is_certificate_pinned(
        Gcr.SimpleCertificate certificate,
        string purpose,
        string peer,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
        return false;
    }

}
