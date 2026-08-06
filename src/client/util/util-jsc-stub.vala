/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Stand-in for the parts of JavaScriptCore that the client uses.
 *
 * JavaScriptCore comes with WebKitGTK, so it is unavailable wherever
 * WebKitGTK is. This file is compiled //only// on those platforms, so
 * that {@link Util.JS} builds unmodified, and is never compiled
 * alongside the real library. See `have_webkit` in meson.build.
 *
 * {@link Util.JS} converts between JS values and GLib.Variant for the
 * bridge between the client and the page. Nothing calls it while the
 * platform has no browser engine, since there is no page to talk to;
 * these values exist only to satisfy the compiler.
 *
 * This file should be deleted rather than implemented: a WebView2 or
 * WKWebView backend exchanges JSON with its page instead of handling
 * engine value types, so {@link Util.JS} wants to move onto
 * GLib.Variant throughout, at which point no platform needs this.
 */
namespace JSC {

    /** A JavaScript execution context. */
    public class Context : GLib.Object {

        public Exception? get_exception() {
            return null;
        }

        public void clear_exception() {
        }

    }

    /** A thrown JavaScript exception. */
    public class Exception : GLib.Object {

        public string to_string() {
            return "";
        }

    }

    /** A JavaScript value. */
    public class Value : GLib.Object {

        public Context context { get; construct; }

        public Value.null(Context context) {
        }

        public Value.boolean(Context context, bool value) {
        }

        public Value.number(Context context, double value) {
        }

        public Value.string(Context context, string value) {
        }

        public Value.object(Context context,
                            void* instance = null,
                            void* klass = null) {
        }

        public Value.array_from_garray(Context context,
                                       GLib.GenericArray<Value> values) {
        }

        public bool is_undefined() { return true; }
        public bool is_null() { return false; }
        public bool is_string() { return false; }
        public bool is_number() { return false; }
        public bool is_boolean() { return false; }
        public bool is_array() { return false; }
        public bool is_object() { return false; }
        public bool is_function() { return false; }
        public bool is_constructor() { return false; }

        public bool to_boolean() { return false; }
        public double to_double() { return 0.0; }
        public int32 to_int32() { return 0; }
        public string to_string() { return ""; }

        public Value object_get_property(string name) {
            return new Value.null(new Context());
        }

        public Value object_get_property_at_index(uint index) {
            return new Value.null(new Context());
        }

        public void object_set_property(string name, Value value) {
        }

        public bool object_has_property(string name) {
            return false;
        }

        public string[]? object_enumerate_properties() {
            return null;
        }

    }

}
