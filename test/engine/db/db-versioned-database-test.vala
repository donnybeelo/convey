/*
 * Copyright 2018 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */


class Convey.Db.VersionedDatabaseTest : TestCase {


    public VersionedDatabaseTest() {
        base("Convey.Db.VersionedDatabaseTest");
        add_test("open_new", open_new);
    }

    public void open_new() throws Error {
        GLib.File tmp_dir = GLib.File.new_for_path(
            GLib.DirUtils.make_tmp("convey-db-database-test-XXXXXX")
        );

        // Close each stream explicitly: this both flushes the script and
        // lets the file be deleted at the end, which Windows will not do
        // while a handle is still open.
        GLib.File sql1 = tmp_dir.get_child("version-001.sql");
        GLib.OutputStream sql1_out = sql1.create(GLib.FileCreateFlags.NONE);
        sql1_out.write("CREATE TABLE TestTable (id INTEGER PRIMARY KEY, col TEXT);".data);
        sql1_out.close();

        GLib.File sql2 = tmp_dir.get_child("version-002.sql");
        GLib.OutputStream sql2_out = sql2.create(GLib.FileCreateFlags.NONE);
        sql2_out.write("INSERT INTO TestTable (col) VALUES ('value');".data);
        sql2_out.close();

        VersionedDatabase db = new VersionedDatabase.persistent(
            tmp_dir.get_child("test.db"), tmp_dir
        );

        db.open.begin(
            Convey.Db.DatabaseFlags.CREATE_FILE, null, this.async_completion
        );
        db.open.end(async_result());

        Convey.Db.Result? result = db.query("SELECT * FROM TestTable;");
        assert_false(result.finished, "Row not inserted");
        assert_equal(result.string_for("col"), "value");
        assert_false(result.next(), "Multiple rows inserted");

        // Drop the result and the database's connection before deleting:
        // Windows will not remove a file that is still open.
        result = null;
        db.close();

        db.file.delete();
        sql1.delete();
        sql2.delete();
        tmp_dir.delete();
    }


}
