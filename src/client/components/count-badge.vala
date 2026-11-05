/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * Draws a count centred on its visible glyph pixels.
 */
public class CountBadge : Gtk.Widget {
    private string text = "";

    static construct {
        set_css_name("label");
        set_accessible_role(Gtk.AccessibleRole.LABEL);
    }

    public void set_text(string text) {
        this.text = text;
        update_property(Gtk.AccessibleProperty.LABEL, text, -1);
        queue_resize();
    }

    private Pango.Layout create_layout() {
        var layout = create_pango_layout(this.text);
        var attrs = new Pango.AttrList();
        attrs.insert(new Pango.AttrFontFeatures("tnum 1"));
        layout.set_attributes(attrs);
        return layout;
    }

    public override void measure(Gtk.Orientation orientation, int for_size,
                                 out int minimum, out int natural,
                                 out int minimum_baseline, out int natural_baseline) {
        var layout = create_layout();
        Pango.Rectangle ink, logical;
        layout.get_extents(out ink, out logical);
        var size = orientation == Gtk.Orientation.HORIZONTAL ? logical.width : logical.height;
        minimum = natural = (int) Math.ceil(Pango.units_to_double(size));
        minimum_baseline = natural_baseline = orientation == Gtk.Orientation.HORIZONTAL ? -1 : (int) Math.round(
            (natural - Pango.units_to_double(ink.height)) / 2
            - Pango.units_to_double(ink.y)
            + Pango.units_to_double(layout.get_baseline())
        );
    }

    public override void snapshot(Gtk.Snapshot snapshot) {
        var layout = create_layout();
        Pango.Rectangle ink, logical;
        layout.get_extents(out ink, out logical);
        var origin = Graphene.Point() {
            x = (float) ((get_width() - Pango.units_to_double(ink.width)) / 2 - Pango.units_to_double(ink.x)),
            y = (float) ((get_height() - Pango.units_to_double(ink.height)) / 2 - Pango.units_to_double(ink.y))
        };
        snapshot.save();
        snapshot.translate(origin);
        snapshot.append_layout(layout, get_color());
        snapshot.restore();
    }
}
