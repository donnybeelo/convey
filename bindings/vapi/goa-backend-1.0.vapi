[CCode (cheader_filename = "goabackend/goabackend.h")]
namespace Goa {
    [CCode (cprefix = "GOA_PROVIDER_FEATURE_", has_type_id = false)]
    [Flags]
    public enum ProviderFeatures {
        BRANDED,
        MAIL
    }

    [CCode (cprefix = "goa_provider_", type_id = "goa_provider_get_type ()")]
    public class Provider : GLib.Object {
        public static Goa.Provider? get_for_provider_type(string provider_type);
        [CCode (async_result_pos = 2.1)]
        public static async bool get_all(out GLib.List<Goa.Provider> providers) throws GLib.Error;
        public unowned string get_provider_type();
        public string get_provider_name(Goa.Object? object);
        public GLib.Icon get_provider_icon(Goa.Object? object);
        public Goa.ProviderFeatures get_provider_features();
        public async Goa.Object add_account(Goa.Client client, Gtk.Widget? parent, GLib.Cancellable? cancellable) throws GLib.Error;
        public async bool show_account(Goa.Client client, Goa.Object object, Gtk.Widget? parent, GLib.Cancellable? cancellable) throws GLib.Error;
    }
}
