/*
 * Copyright © 2017-2020 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Utility functions for WebKit JavaScriptCore (JSC) objects.
 */
namespace Util.JS {

    /**
     * Errors produced by functions in {@link Util.JS}.
     */
    public errordomain Error {
        /**
         * A JS exception was thrown performing a function call.
         */
        EXCEPTION,

        /**
         * A {@link JS.Value} was not of the expected type.
         */
        TYPE
    }

    /** Supported types of JSC values. */
    public enum JscType {

        /** Specifies an unsupported value type. */
        UNKNOWN,

        /** Specifies a JavaScript `undefined` value. */
        UNDEFINED,

        /** Specifies a JavaScript `null` value. */
        NULL,
        FUNCTION,
        STRING,
        NUMBER,
        BOOLEAN,
        ARRAY,
        CONSTRUCTOR,
        OBJECT;

        /**
         * Determines the type of a JSC value.
         *
         * Returns the type of the given value, or {@link UNKNOWN} if
         * it could not be determined.
         */
        public static JscType to_type(JSC.Value value) {
            if (value.is_undefined()) {
                return UNDEFINED;
            }
            if (value.is_null()) {
                return NULL;
            }
            if (value.is_string()) {
                return STRING;
            }
            if (value.is_number()) {
                return NUMBER;
            }
            if (value.is_boolean()) {
                return BOOLEAN;
            }
            if (value.is_array()) {
                return ARRAY;
            }
            if (value.is_object()) {
                return OBJECT;
            }
            if (value.is_function()) {
                return FUNCTION;
            }
            if (value.is_constructor()) {
                return CONSTRUCTOR;
            }
            return UNKNOWN;
        }

    }

    /**
     * Returns a JSC Value as a bool.
     *
     * This will raise a {@link Util.JS.Error.TYPE} error if the
     * value is not a JavaScript `Boolean`.
     */
    public bool to_bool(JSC.Value value)
        throws Util.JS.Error {
        if (!value.is_boolean()) {
            throw new Util.JS.Error.TYPE("Value is not a JS Boolean object");
        }
        bool boolean = value.to_boolean();
        Util.JS.check_exception(value.context);
        return boolean;
    }

    /**
     * Returns a JSC Value as a double.
     *
     * This will raise a {@link Util.JS.Error.TYPE} error if the
     * value is not a JavaScript `Number`.
     */
    public double to_double(JSC.Value value)
        throws Util.JS.Error {
        if (!value.is_number()) {
            throw new Util.JS.Error.TYPE("Value is not a JS Number object");
        }

        double number = value.to_double();
        Util.JS.check_exception(value.context);
        return number;
    }

    /**
     * Returns a JSC Value as an int32.
     *
     * This will raise a {@link Util.JS.Error.TYPE} error if the
     * value is not a JavaScript `Number`.
     */
    public int32 to_int32(JSC.Value value)
        throws Util.JS.Error {
        if (!value.is_number()) {
            throw new Util.JS.Error.TYPE("Value is not a JS Number object");
        }

        int32 number = value.to_int32();
        Util.JS.check_exception(value.context);
        return number;
    }

    /**
     * Returns a JSC Value as a string.
     *
     * This will raise a {@link Util.JS.Error.TYPE} error if the
     * value is not a JavaScript `String`.
     */
    public string to_string(JSC.Value value)
        throws Util.JS.Error {
        if (!value.is_string()) {
            throw new Util.JS.Error.TYPE("Value is not a JS String object");
        }

        string str = value.to_string();
        Util.JS.check_exception(value.context);
        return str;
    }

    /**
     * Returns the value of an object property.
     *
     * This will raise a {@link Util.JS.Error.TYPE} error if the
     * value is not an object or does not contain the named property.
     */
    public inline JSC.Value get_property(JSC.Value value,
                                         string name)
        throws Util.JS.Error {
        if (!value.is_object()) {
            throw new Util.JS.Error.TYPE("Value is not a JS Object");
        }

        JSC.Value property = value.object_get_property(name);
        Util.JS.check_exception(value.context);
        return property;
    }

    /**
     * Checks an JS exception returned from a JSC call.
     *
     * If the given context has a current exception, it will cleared
     * and a {@link Util.JS.Error} will be thrown.
     */
    public inline void check_exception(JSC.Context context)
        throws Error {
        JSC.Exception? exception = context.get_exception();
        if (exception != null) {
            context.clear_exception();
            throw new Error.EXCEPTION(
                "JS exception thrown: %s", exception.to_string()
            );
        }
    }

    /**
     * Converts a JS value to a GLib variant.
     *
     * Simple value objects (string, number, and Boolean values),
     * arrays of these, and objects with these types as properties are
     * supported. Arrays containing objects of the same type are
     * converted to arrays, otherwise they are converted to tuples,
     * empty arrays are converted to the unit tuple, and objects are
     * converted to vardict containing property names as keys and
     * values. Null and undefined values are returned as an empty
     * maybe variant type, since it is not possible to determine the
     * actual type.
     *
     * Throws a type error if the given value's type is not supported.
     */
    public inline GLib.Variant value_to_variant(JSC.Value value)
        throws Error {
        GLib.Variant? variant = null;
        switch (JscType.to_type(value)) {
        case UNDEFINED:
        case NULL:
            variant = new GLib.Variant.maybe(GLib.VariantType.VARIANT, null);
            break;

        case STRING:
            variant = new GLib.Variant.string(value.to_string());
            break;

        case NUMBER:
            variant = new GLib.Variant.double(value.to_double());
            break;

        case BOOLEAN:
            variant = new GLib.Variant.boolean(value.to_boolean());
            break;

        case ARRAY:
            int len = to_int32(value.object_get_property("length"));
            if (len == 0) {
                variant = new GLib.Variant.tuple({});
            } else {
                JSC.Value element = value.object_get_property_at_index(0);
                var first_type = JscType.to_type(element);
                var all_same_type = true;
                var values = new GLib.Variant[len];
                values[0] = value_to_variant(element);
                for (int i = 1; i < len; i++) {
                    element = value.object_get_property_at_index(i);
                    values[i] = value_to_variant(element);
                    all_same_type &= (first_type == JscType.to_type(element));
                }
                if (!all_same_type) {
                    variant = new GLib.Variant.tuple(values);
                } else {
                    variant = new GLib.Variant.array(
                        values[0].get_type(), values
                    );
                }
            }
            break;

        case OBJECT:
            GLib.VariantDict dict = new GLib.VariantDict();
            string[] names = value.object_enumerate_properties();
            if (names != null) {
                foreach (var name in names) {
                    dict.insert_value(
                        name,
                        value_to_variant(value.object_get_property(name))
                    );
                }
            }
            variant = dict.end();
            break;

        default:
            throw new Error.TYPE("Unsupported JS type: %s", value.to_string());
        }
        return variant;
    }

    /**
     * Converts a GLib variant to a JS value.
     *
     * Simple value objects (string, number, and Boolean values),
     * arrays and tuples of these, and dictionaries with string keys
     * are supported. Tuples and arrays are converted to JS arrays,
     * and dictionaries or tuples containing dictionary entries are
     * converted to JS objects.
     *
     * Throws a type error if the given variant's type is not supported.
     */
    public inline JSC.Value variant_to_value(JSC.Context context,
                                             GLib.Variant variant)
        throws Error.TYPE {
        JSC.Value? value = null;
        GLib.Variant.Class type = variant.classify();
        if (type == MAYBE) {
            GLib.Variant? maybe = variant.get_maybe();
            if (maybe != null) {
                value = variant_to_value(context, maybe);
            } else {
                value = new JSC.Value.null(context);
            }
        } else if (type == VARIANT) {
            value = variant_to_value(context, variant.get_variant());
        } else if (type == STRING) {
            value = new JSC.Value.string(context, variant.get_string());
        } else if (type == BOOLEAN) {
            value = new JSC.Value.boolean(context, variant.get_boolean());
        } else if (type == DOUBLE) {
            value = new JSC.Value.number(context, variant.get_double());
        } else if (type == INT64) {
            value = new JSC.Value.number(context, (double) variant.get_int64());
        } else if (type == INT32) {
            value = new JSC.Value.number(context, (double) variant.get_int32());
        } else if (type == INT16) {
            value = new JSC.Value.number(context, (double) variant.get_int16());
        } else if (type == UINT64) {
            value = new JSC.Value.number(context, (double) variant.get_uint64());
        } else if (type == UINT32) {
            value = new JSC.Value.number(context, (double) variant.get_uint32());
        } else if (type == UINT16) {
            value = new JSC.Value.number(context, (double) variant.get_uint16());
        } else if (type == BYTE) {
            value = new JSC.Value.number(context, (double) variant.get_byte());
        } else if (type == ARRAY ||
                   type == TUPLE) {
            size_t len = variant.n_children();
            if (len == 0) {
                if (type == ARRAY ||
                    type == TUPLE) {
                    value = new JSC.Value.array_from_garray(context, null);
                } else {
                    value = new JSC.Value.object(context, null, null);
                }
            } else {
                var first = variant.get_child_value(0);
                if (first.classify() == DICT_ENTRY) {
                    value = new JSC.Value.object(context, null, null);
                    for (size_t i = 0; i < len; i++) {
                        var entry = variant.get_child_value(i);
                        if (entry.classify() != DICT_ENTRY) {
                            throw new Error.TYPE(
                                "Variant mixes dict entries with others: %s",
                                variant.print(true)
                            );
                        }
                        var key = entry.get_child_value(0);
                        if (key.classify() != STRING) {
                            throw new Error.TYPE(
                                "Dict entry key is not a string: %s",
                                entry.print(true)
                            );
                        }
                        value.object_set_property(
                            key.get_string(),
                            variant_to_value(context, entry.get_child_value(1))
                        );
                    }
                } else {
                    var values = new GLib.GenericArray<JSC.Value>((uint) len);
                    for (size_t i = 0; i < len; i++) {
                        values.add(
                            variant_to_value(context, variant.get_child_value(i))
                        );
                    }
                    value = new JSC.Value.array_from_garray(context, values);
                }
            }
        }
        if (value == null) {
            throw new Error.TYPE(
                "Unsupported variant type %s", variant.print(true)
            );
        }
        return value;
    }

    /**
     * Converts a GLib variant to a JSON node.
     *
     * This is the JSON counterpart of {@link variant_to_value}, for
     * engines that exchange JSON with their page rather than handing
     * over engine value types, and produces the same shapes: numbers of
     * every width become JSON numbers, arrays and tuples become JSON
     * arrays, and dictionaries with string keys become JSON objects.
     * Null and empty maybe values become JSON null.
     *
     * Throws a type error if the given variant's type is not supported.
     */
    internal Json.Node variant_to_json(GLib.Variant variant)
        throws Error.TYPE {
        Json.Node? node = null;
        GLib.Variant.Class type = variant.classify();
        if (type == MAYBE) {
            GLib.Variant? maybe = variant.get_maybe();
            node = (
                maybe != null
                ? variant_to_json(maybe)
                : new Json.Node(Json.NodeType.NULL)
            );
        } else if (type == VARIANT) {
            node = variant_to_json(variant.get_variant());
        } else if (type == STRING) {
            node = new Json.Node(Json.NodeType.VALUE);
            node.set_string(variant.get_string());
        } else if (type == BOOLEAN) {
            node = new Json.Node(Json.NodeType.VALUE);
            node.set_boolean(variant.get_boolean());
        } else if (type == DOUBLE ||
                   type == INT64 ||
                   type == INT32 ||
                   type == INT16 ||
                   type == UINT64 ||
                   type == UINT32 ||
                   type == UINT16 ||
                   type == BYTE) {
            node = new Json.Node(Json.NodeType.VALUE);
            node.set_double(to_number(variant, type));
        } else if (type == ARRAY ||
                   type == TUPLE) {
            size_t len = variant.n_children();
            // Ask the type, not the first child, so that an empty
            // dictionary is still written as an object.
            bool is_dict = (
                (type == ARRAY && variant.get_type().element().is_dict_entry())
                || (len > 0 &&
                    variant.get_child_value(0).classify() == DICT_ENTRY)
            );
            if (is_dict) {
                var object = new Json.Object();
                for (size_t i = 0; i < len; i++) {
                    var entry = variant.get_child_value(i);
                    if (entry.classify() != DICT_ENTRY) {
                        throw new Error.TYPE(
                            "Variant mixes dict entries with others: %s",
                            variant.print(true)
                        );
                    }
                    var key = entry.get_child_value(0);
                    if (key.classify() != STRING) {
                        throw new Error.TYPE(
                            "Dict entry key is not a string: %s",
                            entry.print(true)
                        );
                    }
                    object.set_member(
                        key.get_string(),
                        variant_to_json(entry.get_child_value(1))
                    );
                }
                node = new Json.Node(Json.NodeType.OBJECT);
                node.set_object(object);
            } else {
                var array = new Json.Array.sized((uint) len);
                for (size_t i = 0; i < len; i++) {
                    array.add_element(
                        variant_to_json(variant.get_child_value(i))
                    );
                }
                node = new Json.Node(Json.NodeType.ARRAY);
                node.set_array(array);
            }
        }
        if (node == null) {
            throw new Error.TYPE(
                "Unsupported variant type %s", variant.print(true)
            );
        }
        return node;
    }

    /**
     * Converts a JSON node to a GLib variant.
     *
     * This is the JSON counterpart of {@link value_to_variant}, and
     * produces the same variants that it does for the equivalent JS
     * values, which is what {@link Components.WebView} and its
     * subclasses expect of anything arriving from their page: JSON
     * numbers become doubles whether or not they are integral, arrays
     * of a single variant type become variant arrays and mixed arrays
     * become tuples, empty arrays become the unit tuple, objects become
     * vardicts, and null becomes an empty maybe.
     *
     * Throws a type error if the node holds a value JSON has no
     * business holding, which in practice means a boxed GObject type.
     */
    internal GLib.Variant json_to_variant(Json.Node node)
        throws Error.TYPE {
        GLib.Variant? variant = null;
        switch (node.get_node_type()) {
        case NULL:
            variant = new GLib.Variant.maybe(GLib.VariantType.VARIANT, null);
            break;

        case VALUE:
            GLib.Type value_type = node.get_value_type();
            if (value_type == typeof(string)) {
                variant = new GLib.Variant.string(node.get_string());
            } else if (value_type == typeof(bool)) {
                variant = new GLib.Variant.boolean(node.get_boolean());
            } else if (value_type == typeof(int64) ||
                       value_type == typeof(double)) {
                // JS has a single number type, so callers only ever
                // check for a double. json-glib parses an integral
                // literal as an int64, hence the widening here.
                variant = new GLib.Variant.double(node.get_double());
            } else {
                throw new Error.TYPE(
                    "Unsupported JSON value type: %s", value_type.name()
                );
            }
            break;

        case ARRAY:
            Json.Array array = node.get_array();
            uint len = array.get_length();
            if (len == 0) {
                variant = new GLib.Variant.tuple({});
            } else {
                var values = new GLib.Variant[len];
                var all_same_type = true;
                for (uint i = 0; i < len; i++) {
                    values[i] = json_to_variant(array.get_element(i));
                    // Compare variant types rather than JSON node
                    // types, unlike value_to_variant: two arrays are
                    // both JSON arrays but may still convert to
                    // variants of different types, which GLib.Variant
                    // refuses to put in one array.
                    all_same_type &= values[i].get_type().equal(
                        values[0].get_type()
                    );
                }
                variant = (
                    all_same_type
                    ? new GLib.Variant.array(values[0].get_type(), values)
                    : new GLib.Variant.tuple(values)
                );
            }
            break;

        case OBJECT:
            var dict = new GLib.VariantDict();
            Json.Object object = node.get_object();
            foreach (string name in object.get_members()) {
                dict.insert_value(
                    name, json_to_variant(object.get_member(name))
                );
            }
            variant = dict.end();
            break;
        }
        if (variant == null) {
            throw new Error.TYPE("Unsupported JSON node");
        }
        return variant;
    }

    private inline double to_number(GLib.Variant variant,
                                    GLib.Variant.Class type) {
        double number = 0;
        if (type == DOUBLE) {
            number = variant.get_double();
        } else if (type == INT64) {
            number = (double) variant.get_int64();
        } else if (type == INT32) {
            number = (double) variant.get_int32();
        } else if (type == INT16) {
            number = (double) variant.get_int16();
        } else if (type == UINT64) {
            number = (double) variant.get_uint64();
        } else if (type == UINT32) {
            number = (double) variant.get_uint32();
        } else if (type == UINT16) {
            number = (double) variant.get_uint16();
        } else if (type == BYTE) {
            number = (double) variant.get_byte();
        }
        return number;
    }

    /**
     * Convenience method for returning a new Callable instance.
     */
    public Callable callable(string base_name) {
        return new Callable(base_name);
    }

    /**
     * A class for constructing a well formed, safe, invocable JS call.
     */
    public class Callable {

        private string name;
        private GLib.Variant[] args = {};


        public Callable(string name) {
            this.name = name;
        }

        public string get_name() {
            return this.name;
        }

        public GLib.Variant? to_parameters() {
            GLib.Variant? args = null;
            if (this.args.length == 1) {
                args = this.args[0];
            } else if (this.args.length > 1) {
                args = new GLib.Variant.tuple(this.args);
            }
            return args;
        }

        public string to_string() {
            string[] args = new string[this.args.length];
            for (int i = 0; i < args.length; i++) {
                args[i] = this.args[i].print(true);
            }
            return this.name + "(" + global::string.joinv(",", args) + ")";
        }

        public Callable string(string value) {
            add_param(new GLib.Variant.string(value));
            return this;
        }

        public Callable double(double value) {
            add_param(new GLib.Variant.double(value));
            return this;
        }

        public Callable int(int value) {
            add_param(new GLib.Variant.int32(value));
            return this;
        }

        public Callable bool(bool value) {
            add_param(new GLib.Variant.boolean(value));
            return this;
        }

        private inline void add_param(GLib.Variant value) {
            this.args += value;
        }

    }

}
