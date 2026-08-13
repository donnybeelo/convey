/*
 * Copyright © 2017-2020 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

public class Util.JS.Test : TestCase {


    private JSC.Context? context = null;


    public Test() {
        base("Util.JS.Test");
        add_test("to_variant", to_variant);
        add_test("to_value", to_value);
        add_test("to_json", to_json);
        add_test("from_json", from_json);
    }

    public override void set_up() throws GLib.Error {
        this.context = new JSC.Context();
    }

    public override void tear_down() throws GLib.Error {
        this.context = null;
    }

    public void to_variant() throws GLib.Error {
        assert_equal(
            value_to_variant(new JSC.Value.null(this.context)).print(true),
            "@mv nothing"
        );
        assert_equal(
            value_to_variant(new JSC.Value.string(this.context, "test")).print(true),
            "'test'"
        );
        assert_equal(
            value_to_variant(new JSC.Value.number(this.context, 1.0)).print(true),
            "1.0"
        );
        assert_equal(
            value_to_variant(new JSC.Value.boolean(this.context, true)).print(true),
            "true"
        );
        assert_equal(
            value_to_variant(new JSC.Value.boolean(this.context, false)).print(true),
            "false"
        );

        var value = new JSC.Value.array_from_garray(this.context, null);
        assert_equal(
            value_to_variant(value).print(true),
            "()"
        );

        var array = new GLib.GenericArray<JSC.Value>();
        array.add(new JSC.Value.string(this.context, "test"));
        value = new JSC.Value.array_from_garray(this.context, array);
        assert_equal(
            value_to_variant(value).print(true),
            "['test']"
        );

        array = new GLib.GenericArray<JSC.Value>();
        array.add(new JSC.Value.string(this.context, "test1"));
        array.add(new JSC.Value.string(this.context, "test2"));
        value = new JSC.Value.array_from_garray(this.context, array);
        assert_equal(
            value_to_variant(value).print(true),
            "['test1', 'test2']"
        );

        array = new GLib.GenericArray<JSC.Value>();
        array.add(new JSC.Value.string(this.context, "test"));
        array.add(new JSC.Value.boolean(this.context, true));
        value = new JSC.Value.array_from_garray(this.context, array);
        assert_equal(
            value_to_variant(value).print(true),
            "('test', true)"
        );

        value = new JSC.Value.object(this.context, null, null);
        assert_equal(
            value_to_variant(value).print(true),
            "@a{sv} {}"
        );
        value.object_set_property(
            "test", new JSC.Value.boolean(this.context, true)
        );
        assert_equal(
            value_to_variant(value).print(true),
            "{'test': <true>}"
        );
    }

    public void to_value() throws GLib.Error {
        var variant = new GLib.Variant.maybe(GLib.VariantType.STRING, null);
        var value = variant_to_value(this.context, variant);
        assert_true(value.is_null(), variant.print(true));

        variant = new GLib.Variant.string("test");
        value = variant_to_value(this.context, variant);
        assert_true(value.is_string(), variant.print(true));
        assert_equal(value.to_string(), "test", variant.print(true));

        variant = new GLib.Variant.int32(42);
        value = variant_to_value(this.context, variant);
        assert_true(value.is_number(), variant.print(true));
        assert_equal<int32?>(value.to_int32(), 42, variant.print(true));

        variant = new GLib.Variant.double(42.0);
        value = variant_to_value(this.context, variant);
        assert_true(value.is_number(), variant.print(true));
        assert_within(value.to_double(), 42.0, 0.0000001, variant.print(true));

        variant = new GLib.Variant.boolean(true);
        value = variant_to_value(this.context, variant);
        assert_true(value.is_boolean(), variant.print(true));
        assert_true(value.to_boolean(), variant.print(true));

        variant = new GLib.Variant.boolean(false);
        value = variant_to_value(this.context, variant);
        assert_true(value.is_boolean(), variant.print(true));
        assert_false(value.to_boolean(), variant.print(true));

        variant = new GLib.Variant.strv({"test"});
        value = variant_to_value(this.context, variant);
        assert_true(value.is_array(), variant.print(true));
        assert_true(
            value.object_get_property_at_index(0).is_string(),
            variant.print(true)
        );
        assert_equal(
            value.object_get_property_at_index(0).to_string(),
            "test",
            variant.print(true)
        );

        var dict = new GLib.VariantDict();
        variant = dict.end();
        value = variant_to_value(this.context, variant);
        assert_true(value.is_object(), variant.print(true));

        dict = new GLib.VariantDict();
        dict.insert_value("test", new GLib.Variant.boolean(true));
        variant = dict.end();
        value = variant_to_value(this.context, variant);
        assert_true(value.is_object(), variant.print(true));
        assert_true(
            value.object_get_property("test").is_boolean(),
            value.to_string()
        );
        assert_true(
            value.object_get_property("test").to_boolean(),
            value.to_string()
        );
    }

    public void to_json() throws GLib.Error {
        assert_equal(
            print_json(new GLib.Variant.maybe(GLib.VariantType.STRING, null)),
            "null"
        );
        assert_equal(print_json(new GLib.Variant.string("test")), "\"test\"");
        assert_equal(print_json(new GLib.Variant.boolean(true)), "true");
        assert_equal(print_json(new GLib.Variant.boolean(false)), "false");
        // Every variant width lands on a JS number, so json-glib
        // writes it as a double. JSON has one number type too.
        assert_equal(print_json(new GLib.Variant.int32(42)), "42.0");
        assert_equal(print_json(new GLib.Variant.double(42.5)), "42.5");
        assert_equal(print_json(new GLib.Variant.tuple({})), "[]");
        assert_equal(print_json(new GLib.Variant.strv({"one", "two"})),
                     "[\"one\",\"two\"]");
        assert_equal(
            print_json(
                new GLib.Variant.tuple({
                    new GLib.Variant.string("one"),
                    new GLib.Variant.boolean(true)
                })
            ),
            "[\"one\",true]"
        );

        var dict = new GLib.VariantDict();
        assert_equal(print_json(dict.end()), "{}");

        dict = new GLib.VariantDict();
        dict.insert_value("test", new GLib.Variant.boolean(true));
        assert_equal(print_json(dict.end()), "{\"test\":true}");
    }

    public void from_json() throws GLib.Error {
        assert_equal(parse_json("null").print(true), "@mv nothing");
        assert_equal(parse_json("\"test\"").print(true), "'test'");
        assert_equal(parse_json("true").print(true), "true");
        assert_equal(parse_json("false").print(true), "false");
        // Integral literals must still arrive as doubles: the page's
        // numbers are all JS numbers, and callers only unpack doubles.
        assert_equal(parse_json("42").print(true), "42.0");
        assert_equal(parse_json("42.5").print(true), "42.5");
        assert_equal(parse_json("[]").print(true), "()");
        assert_equal(parse_json("[\"one\", \"two\"]").print(true),
                     "['one', 'two']");
        assert_equal(parse_json("[\"one\", true]").print(true),
                     "('one', true)");
        // Same JSON type, different variant types: must not be forced
        // into a single array.
        assert_equal(parse_json("[[1], [\"one\"]]").print(true),
                     "([1.0], ['one'])");
        assert_equal(parse_json("{}").print(true), "@a{sv} {}");
        assert_equal(parse_json("{\"test\": true}").print(true),
                     "{'test': <true>}");
        assert_equal(parse_json("{\"test\": [1, 2]}").print(true),
                     "{'test': <[1.0, 2.0]>}");
    }

    private string print_json(GLib.Variant variant) throws GLib.Error {
        var generator = new Json.Generator();
        generator.set_root(variant_to_json(variant));
        return generator.to_data(null);
    }

    private GLib.Variant parse_json(string json) throws GLib.Error {
        var parser = new Json.Parser();
        parser.load_from_data(json);
        return json_to_variant(parser.get_root());
    }
}
