/*
 * Copyright 2026 Daniel Elia <d.elia@outlook.com>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Remembers the real subjects of encrypted email, keyed by Message-ID.
 */
public class Application.DecryptedSubjects : Convey.BaseObject {


    private const string ATTR_KIND = "kind";
    private const string KIND = "subjects";

    private static Secret.Schema schema = new Secret.Schema(
        Application.Client.SCHEMA_ID + ".DecryptedSubjects",
        Secret.SchemaFlags.NONE,
        ATTR_KIND, Secret.SchemaAttributeType.STRING,
        null
    );

    private Gee.Map<string,string> subjects = new Gee.HashMap<string,string>();


    public DecryptedSubjects(GLib.File legacy_file) {
        try {
            string? contents = Secret.password_lookup_sync(
                schema, null, ATTR_KIND, KIND
            );
            if (contents != null) {
                var parser = new Json.Parser();
                parser.load_from_data(contents);
                Json.Object root = parser.get_root().get_object();
                foreach (string id in root.get_members()) {
                    this.subjects.set(id, root.get_string_member(id));
                }
            }
        } catch (GLib.Error err) {
            warning("Unable to load decrypted subjects: %s", err.message);
        }

        try {
            legacy_file.delete();
        } catch (GLib.IOError.NOT_FOUND err) {
        } catch (GLib.Error err) {
            warning("Unable to delete legacy decrypted subjects: %s", err.message);
        }
    }

    public string? get(Convey.RFC822.MessageID? id) {
        return id != null ? this.subjects.get(id.value) : null;
    }

    public string get_display_subject(Convey.Email email) {
        string? decrypted = get(email.message_id);
        return decrypted != null
            ? new Convey.RFC822.Subject(decrypted).strip_prefixes()
            : Util.Email.strip_subject_prefixes(email);
    }

    public void set(Convey.RFC822.MessageID id, string subject) {
        if (this.subjects.get(id.value) == subject) {
            return;
        }
        this.subjects.set(id.value, subject);

        var builder = new Json.Builder();
        builder.begin_object();
        foreach (var entry in this.subjects.entries) {
            builder.set_member_name(entry.key);
            builder.add_string_value(entry.value);
        }
        builder.end_object();
        var generator = new Json.Generator();
        generator.set_root(builder.get_root());
        Secret.password_store.begin(
            schema, Secret.COLLECTION_DEFAULT, "Convey decrypted subjects",
            generator.to_data(null), null,
            (obj, res) => {
                try {
                    Secret.password_store.end(res);
                } catch (GLib.Error err) {
                    warning("Unable to save decrypted subjects: %s", err.message);
                }
            },
            ATTR_KIND, KIND
        );
    }

}
