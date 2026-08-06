/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Stand-in for the parts of libfolks that the client uses.
 *
 * libfolks is Linux-only: it aggregates contacts over D-Bus from
 * Evolution Data Server and friends. This file is compiled //only// on
 * platforms where folks is unavailable, so that {@link
 * Application.Contact} and {@link Application.ContactStore} build
 * unmodified, and is never compiled alongside the real library. See
 * `have_folks` in meson.build.
 *
 * Everything here is inert: the aggregator holds no individuals and
 * searches return nothing, so the client falls back to the contact
 * information the engine records for itself, which is where display
 * names for correspondents come from in any case. What is lost is the
 * system address book: no avatars or starred contacts from it, no
 * completion against it, and no saving a contact into it.
 *
 * Replacing this with a real implementation on Windows means the
 * Windows.ApplicationModel.Contacts API, and on macOS the Contacts
 * framework. Both would want to keep this API shape so the two callers
 * above stay platform-independent.
 */
namespace Folks {

    /** Determines the reliability of an individual's data. */
    public enum TrustLevel {
        NONE,
        PERSONAS;
    }

    /** A tri-state boolean, as used by folks for store capabilities. */
    public enum MaybeBool {
        UNSET,
        TRUE,
        FALSE;
    }

    /** The detail keys an individual may carry. */
    public enum PersonaDetail {
        FULL_NAME,
        EMAIL_ADDRESSES;
    }

    /** A single email address belonging to an individual. */
    public class EmailFieldDetails : GLib.Object {

        public string value { get; construct; }

        public EmailFieldDetails(string value) {
            Object(value: value);
        }

    }

    /** A contact aggregated from one or more personas. */
    public class Individual : GLib.Object {

        public string id { get; default = ""; }

        public string? display_name { get; default = null; }

        public bool is_favourite { get; default = false; }

        public GLib.LoadableIcon? avatar { get; default = null; }

        public TrustLevel trust_level { get; default = TrustLevel.NONE; }

        public Gee.Set<EmailFieldDetails> email_addresses {
            get; default = new Gee.HashSet<EmailFieldDetails>();
        }

        /** Emitted when the individual is no longer available. */
        public signal void removed(Individual? replacement);

        public async void change_is_favourite(bool is_favourite)
            throws GLib.Error {
            throw new GLib.IOError.NOT_SUPPORTED(
                "No contact store on this platform"
            );
        }

    }

    /** One source's view of a contact. */
    public class Persona : GLib.Object {

        public Individual? individual { get; default = null; }

    }

    /** A backing store of personas. */
    public class PersonaStore : GLib.Object {

        public MaybeBool can_add_personas {
            get; default = MaybeBool.FALSE;
        }

        public static string detail_key(PersonaDetail detail) {
            switch (detail) {
            case PersonaDetail.FULL_NAME:
                return "full-name";
            case PersonaDetail.EMAIL_ADDRESSES:
                return "email-addresses";
            default:
                return "";
            }
        }

        public async Persona? add_persona_from_details(
            GLib.HashTable<string,GLib.Value?> details
        ) throws GLib.Error {
            throw new GLib.IOError.NOT_SUPPORTED(
                "No contact store on this platform"
            );
        }

    }

    /** Base class for individual queries. */
    public abstract class Query : GLib.Object {

        /** The detail fields a query matches against by default. */
        public const string[] MATCH_FIELDS_NAMES = {
            "alias", "full-name", "nickname", "structured-name"
        };

        public string[] match_fields { get; set; default = {}; }

    }

    /** A substring query over an individual's details. */
    public class SimpleQuery : Query {

        public SimpleQuery(string query, string[] match_fields) {
            Object(match_fields: match_fields);
        }

    }

    /** Aggregates individuals from every available persona store. */
    public class IndividualAggregator : GLib.Object {

        private static IndividualAggregator? instance = null;

        public PersonaStore? primary_store { get; default = null; }

        /** Emitted when the set of aggregated individuals changes. */
        public signal void individuals_changed_detailed(
            Gee.MultiMap<Individual?,Individual?> changes
        );

        public static IndividualAggregator dup() {
            if (IndividualAggregator.instance == null) {
                IndividualAggregator.instance = new IndividualAggregator();
            }
            return IndividualAggregator.instance;
        }

        public async void prepare() throws GLib.Error {
            // Nothing to prepare.
        }

    }

    /** A live view of the individuals matching a query. */
    public class SearchView : GLib.Object {

        public Gee.Collection<Individual> individuals {
            get; default = new Gee.LinkedList<Individual>();
        }

        public SearchView(IndividualAggregator aggregator, Query query) {
            Object();
        }

        public async void prepare() throws GLib.Error {
            // Nothing to prepare: the result set is always empty.
        }

    }

}
