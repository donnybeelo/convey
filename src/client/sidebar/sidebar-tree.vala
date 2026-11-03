/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * A navigation sidebar backed by {@link Gtk.ListView} and
 * {@link Gtk.TreeListModel}.
 *
 * The domain model is provided by {@link Sidebar.Branch} and
 * {@link Sidebar.Entry}; this widget mirrors each grafted branch into a
 * tree of {@link Node}s (each holding an ordered child list store) which
 * the tree list model presents lazily.
 */
public class Sidebar.Tree : Gtk.Widget, Gtk.Scrollable {
    public const int ICON_SIZE = 16;

    // Only one ExternalDropHandler can be registered with the Tree; it's
    // responsible for completing an external drag.
    public delegate void ExternalDropHandler(Gtk.DropTarget context, Sidebar.Entry? entry);

    // How long rows take to fade in when added and out when removed.
    private const uint FADE_DURATION_MS = 200;

    // A node in the sidebar's tree model, mirroring one Sidebar.Entry.
    private class Node : GLib.Object {
        public Sidebar.Entry entry;
        public weak Node? parent;
        public int root_position = 0; // only meaningful for root nodes
        public GLib.ListStore children = new GLib.ListStore(typeof(Node));

        // Row widgets, non-null only while the node's row is realised.
        public weak Gtk.TreeExpander? expander_widget = null;
        public weak Gtk.Image? icon_widget = null;
        public weak Gtk.Spinner? spinner_widget = null;
        public weak Gtk.Label? name_widget = null;
        public weak CountBadge? count_widget = null;
        public ulong children_handler = 0;
        public ulong expanded_handler = 0;
        public bool expansion_restored = false;

        // Set while the row is fading in or out (see FADE_DURATION_MS).
        public bool fade_in = false;
        public bool fading_out = false;
        public bool unregistered = false;

        public Node(Sidebar.Entry entry, Node? parent) {
            this.entry = entry;
            this.parent = parent;
        }
    }

    // GtkListView is a final class and can't be subclassed, so the tree
    // wraps one and forwards scrolling to it via Gtk.Scrollable. Created
    // inline so it exists before any construct-time property setter runs.
    private Gtk.ListView list_view = new Gtk.ListView(null, null);
    private GLib.ListStore roots = new GLib.ListStore(typeof(Node));
    private Gtk.TreeListModel tree_model;
    private Gtk.SingleSelection selection;

    // Gtk.Scrollable: forward everything to the inner list view.
    public Gtk.Adjustment hadjustment {
        get { return this.list_view.hadjustment; }
        set construct { if (this.list_view != null) this.list_view.hadjustment = value; }
    }
    public Gtk.Adjustment vadjustment {
        get { return this.list_view.vadjustment; }
        set construct { if (this.list_view != null) this.list_view.vadjustment = value; }
    }
    public Gtk.ScrollablePolicy hscroll_policy {
        get { return this.list_view.hscroll_policy; }
        set { this.list_view.hscroll_policy = value; }
    }
    public Gtk.ScrollablePolicy vscroll_policy {
        get { return this.list_view.vscroll_policy; }
        set { this.list_view.vscroll_policy = value; }
    }

    public bool get_border(out Gtk.Border border) {
        return this.list_view.get_border(out border);
    }

    private Gee.HashMap<Sidebar.Entry, Node> node_map =
        new Gee.HashMap<Sidebar.Entry, Node>();
    private Gee.HashMap<Sidebar.Branch, int> branches =
        new Gee.HashMap<Sidebar.Branch, int>();

    private int editing_disabled = 0;
    private bool mask_entry_selected_signal = false;
    private bool updating_selection = false;
    private uint last_selected_position = Gtk.INVALID_LIST_POSITION;
    // Node the keyboard cursor is on. Moves with the arrow keys without
    // changing the selection; Enter/Space commits it as the selection.
    private weak Node? cursor_node = null;
    private uint focus_cursor_source = 0;
    // The logically selected entry. Persists across expand/collapse: it
    // identifies the actual selected Sidebar.Entry, independent of which
    // GTK list index (if any) currently represents it visually.
    private weak Node? selected_node = null;
    /** Menu shown on secondary click, unless a subclass overrides it. */
    public Gtk.PopoverMenu? default_context_menu { get; set; default = null; }

    private Node? context_node = null;

    // Set while mail is being dragged over the window, hiding rows that
    // can't accept it.
    private bool drag_active = false;

    // Set while sync_visual_selection() is repointing the GTK selection
    // index at a stand-in row (e.g. a collapsed ancestor); on_selection_changed
    // must not treat that as a new user selection.
    private bool syncing_visual_selection = false;

    // GtkListView's single-click-activate selects on hover, which we don't
    // want; instead single-click activation is driven from a click gesture.
    private bool click_selecting = false;
    private bool activated_this_click = false;

    /** The entry the context menu was last invoked on, if any. */
    public Sidebar.Entry? context_entry {
        get { return (this.context_node != null) ? this.context_node.entry : null; }
    }

    /** Fired just before the context menu is shown. */
    public signal void context_menu_requested(Sidebar.Entry? entry);

    /**
     * Hides every row that can't accept a drop, for the duration of one.
     *
     * @see entry_accepts_drop
     */
    public void set_drag_active(bool active) {
        if (this.drag_active == active)
            return;

        this.drag_active = active;
        this.suppress_expansion_signal = true;
        if (active) {
            expand_for_drag();
        }
        foreach (var node in this.node_map.values) {
            refresh_row(node);
        }
        if (!active) {
            collapse_after_drag();
        }
        this.suppress_expansion_signal = false;
    }

    // Entries expanded by expand_for_drag, collapsed again by
    // collapse_after_drag
    private Gee.ArrayList<Sidebar.Entry> drag_expanded =
        new Gee.ArrayList<Sidebar.Entry>();

    private void expand_for_drag() {
        this.drag_expanded.clear();
        bool expanded_one = true;
        while (expanded_one) {
            expanded_one = false;
            uint n = this.tree_model.get_n_items();
            for (uint i = 0; i < n; i++) {
                var row = this.tree_model.get_row(i);
                if (row == null ||
                    !row.is_expandable() ||
                    row.get_expanded()) {
                    continue;
                }

                var node = row.get_item() as Node;
                if (node != null) {
                    this.drag_expanded.add(node.entry);
                }
                // Restarts the scan, since expanding shifts every
                // position after this one
                row.set_expanded(true);
                expanded_one = true;
                break;
            }
        }
    }

    private void collapse_row(Node node) {
        uint pos = position_of(node);
        if (pos == Gtk.INVALID_LIST_POSITION) {
            return;
        }
        var row = this.tree_model.get_row(pos);
        if (row == null ||
            !row.is_expandable() ||
            !row.get_expanded()) {
            return;
        }

        without_expansion_signal(() => row.set_expanded(false));
    }

    private void collapse_after_drag() {
        foreach (var entry in this.drag_expanded) {
            Node? node = this.node_map.get(entry);
            if (node == null) {
                continue;
            }
            uint pos = position_of(node);
            if (pos != Gtk.INVALID_LIST_POSITION) {
                var row = this.tree_model.get_row(pos);
                if (row != null) {
                    row.set_expanded(false);
                }
            }
        }
        this.drag_expanded.clear();
    }

    /** Fired when an entry is expanded or collapsed by the user. */
    public signal void entry_expansion_changed(Sidebar.Entry entry,
                                               bool expanded);

    // Set while the tree itself is expanding or collapsing rows, so
    // that only the user's own toggles are reported
    private bool suppress_expansion_signal = false;

    private delegate void ExpansionAction();

    // Runs action without entry_expansion_changed being fired for it
    private void without_expansion_signal(ExpansionAction action) {
        bool was_suppressed = this.suppress_expansion_signal;
        this.suppress_expansion_signal = true;
        action();
        this.suppress_expansion_signal = was_suppressed;
    }

    /** Determines if an entry was left collapsed by the user. */
    protected virtual bool is_collapsed(Sidebar.Entry entry) {
        return false;
    }

    /** Determines if an entry stays visible while a drag is in progress. */
    protected virtual bool entry_accepts_drop(Sidebar.Entry entry) {
        return true;
    }

    /** Returns the context menu to open on the given entry, if any. */
    protected virtual Gtk.PopoverMenu? get_context_menu(Sidebar.Entry? entry) {
        return this.default_context_menu;
    }

    public signal void entry_selected(Sidebar.SelectableEntry selectable);

    public signal void entry_activated(Sidebar.SelectableEntry selectable);

    public signal void selected_entry_removed(Sidebar.SelectableEntry removed);

    public signal void branch_added(Sidebar.Branch branch);

    public signal void branch_removed(Sidebar.Branch branch);

    public signal void branch_shown(Sidebar.Branch branch, bool shown);

    static construct {
        set_layout_manager_type(typeof(Gtk.BinLayout));
    }

    public Tree() {
        this.tree_model = new Gtk.TreeListModel(
            this.roots, false, false, (item) => ((Node) item).children
        );
        this.selection = new Gtk.SingleSelection(this.tree_model) {
            autoselect = false,
            can_unselect = true
        };

        var factory = new Gtk.SignalListItemFactory();
        factory.setup.connect(on_setup_row);
        factory.bind.connect(on_bind_row);
        factory.unbind.connect(on_unbind_row);

        this.list_view.set_model(this.selection);
        this.list_view.set_factory(factory);
        this.list_view.add_css_class("navigation-sidebar");
        this.list_view.single_click_activate = false;
        this.list_view.set_parent(this);

        this.selection.selection_changed.connect(on_selection_changed);
        this.list_view.activate.connect(on_row_activated);
        // Expanding/collapsing a row changes which rows are visible, which
        // may hide or reveal the current selection's own row; keep the
        // GTK selection index pointed at the right stand-in row whenever
        // that happens.
        this.tree_model.items_changed.connect(() => {
            sync_visual_selection();
            queue_focus_cursor_row();
        });

        // Accepts conversation drags from the conversation list, which
        // provide a string marker; the actual conversations moved are
        // the main window's current selection.
        var drop_target = new Gtk.DropTarget(
            typeof(string), Gdk.DragAction.COPY | Gdk.DragAction.MOVE
        );
        drop_target.drop.connect(on_drop_target_drop);
        this.list_view.add_controller(drop_target);

        // Capture phase so arrow keys are handled here before GtkListView's
        // own bindings, which would move the selection (and hence switch
        // folders) rather than just the keyboard cursor.
        var key_controller = new Gtk.EventControllerKey() {
            propagation_phase = Gtk.PropagationPhase.CAPTURE
        };
        key_controller.key_pressed.connect(on_key_pressed);
        this.list_view.add_controller(key_controller);

        var click_gesture = new Gtk.GestureClick() {
            button = Gdk.BUTTON_SECONDARY
        };
        click_gesture.pressed.connect(on_secondary_press);
        this.list_view.add_controller(click_gesture);

        // Drives single-click activation without GtkListView's
        // select-on-hover behaviour. Runs in the capture phase so the flag
        // is set before the list view updates the selection.
        var primary_gesture = new Gtk.GestureClick() {
            button = Gdk.BUTTON_PRIMARY,
            propagation_phase = Gtk.PropagationPhase.CAPTURE
        };
        primary_gesture.pressed.connect(on_primary_pressed);
        primary_gesture.released.connect(on_primary_released);
        this.list_view.add_controller(primary_gesture);

        var focus_controller = new Gtk.EventControllerFocus();
        focus_controller.enter.connect(queue_focus_cursor_row);
        this.list_view.add_controller(focus_controller);
    }

    private void queue_focus_cursor_row() {
        if (this.focus_cursor_source != 0)
            return;
        this.focus_cursor_source = GLib.Idle.add(() => {
            this.focus_cursor_source = 0;
            focus_cursor_row();
            return GLib.Source.REMOVE;
        });
    }

    private void focus_cursor_row() {
        // Only ever move the focus within the list, never pull it here.
        if (!this.list_view.has_focus && this.list_view.get_focus_child() == null)
            return;
        uint pos = cursor_or_selection();
        if (pos != Gtk.INVALID_LIST_POSITION)
            this.list_view.scroll_to(pos, Gtk.ListScrollFlags.FOCUS, null);
    }

    ~Tree() {
        if (this.focus_cursor_source != 0)
            GLib.Source.remove(this.focus_cursor_source);
        if (this.list_view != null)
            this.list_view.unparent();
    }

    public override bool grab_focus() {
        return this.list_view.grab_focus();
    }

    //
    // Row factory
    //

    private void on_setup_row(GLib.Object object) {
        var list_item = (Gtk.ListItem) object;
        var icon = new Gtk.Image();
        var spinner = new Gtk.Spinner() { visible = false };
        var name = new Gtk.Label(null) {
            use_markup = true,
            ellipsize = Pango.EllipsizeMode.END,
            xalign = 0,
            hexpand = true
        };
        var count = new CountBadge() {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER
        };
        count.add_css_class("sidebar-count");
        var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6) {
            // The row's visual padding lives here (see CSS) rather than on
            // the list item's row container, so a click anywhere in that
            // padding still lands on box and resolves to this row's node.
            hexpand = true,
            vexpand = true
        };
        box.add_css_class("sidebar-row-content");
        box.append(icon);
        box.append(spinner);
        box.append(name);
        box.append(count);
        var expander = new Gtk.TreeExpander() {
            child = box,
            hexpand = true,
            vexpand = true
        };
        list_item.child = expander;
    }

    private void on_bind_row(GLib.Object object) {
        var list_item = (Gtk.ListItem) object;
        var row = (Gtk.TreeListRow) list_item.get_item();
        var node = (Node) row.get_item();
        var expander = (Gtk.TreeExpander) list_item.child;
        expander.set_list_row(row);

        var box = (Gtk.Box) expander.child;
        var icon = (Gtk.Image) box.get_first_child();
        var spinner = (Gtk.Spinner) icon.get_next_sibling();
        var name = (Gtk.Label) spinner.get_next_sibling();
        var count = (CountBadge) name.get_next_sibling();

        box.set_data("sidebar-node", node);
        node.expander_widget = expander;
        node.icon_widget = icon;
        node.spinner_widget = spinner;
        node.name_widget = name;
        node.count_widget = count;
        node.children_handler = node.children.items_changed.connect(() => {
            if (node.expander_widget != null)
                node.expander_widget.hide_expander =
                    (node.children.get_n_items() == 0);
        });
        node.expanded_handler = row.notify["expanded"].connect(() => {
            if (!this.suppress_expansion_signal) {
                entry_expansion_changed(node.entry, row.get_expanded());
            }
        });

        // Applies the saved state the first time each row appears
        if (!node.expansion_restored) {
            node.expansion_restored = true;
            if (is_collapsed(node.entry)) {
                GLib.Idle.add(() => {
                    collapse_row(node);
                    return GLib.Source.REMOVE;
                });
            }
        }

        refresh_row(node);

        if (node.fade_in) {
            node.fade_in = false;
            fade_row(node, 0.0, 1.0, null);
        }
    }

    // Animates the node's row between two opacities, calling done (if
    // given) when it finishes. Does nothing if the row isn't realised.
    private void fade_row(Node node, double from, double to,
                          owned Adw.AnimationTargetFunc? done) {
        Gtk.TreeExpander? widget = node.expander_widget;
        if (widget == null) {
            if (done != null)
                done(to);
            return;
        }

        widget.opacity = from;
        var target = new Adw.CallbackAnimationTarget((value) => {
            // The row may have been recycled onto another node mid-flight
            if (node.expander_widget == widget)
                widget.opacity = value;
        });
        var animation = new Adw.TimedAnimation(
            widget, from, to, FADE_DURATION_MS, target
        );
        animation.done.connect(() => {
            widget.opacity = 1.0;
            if (done != null)
                done(to);
        });
        animation.play();
    }

    private void on_unbind_row(GLib.Object object) {
        var list_item = (Gtk.ListItem) object;
        var expander = (Gtk.TreeExpander) list_item.child;
        expander.set_list_row(null);
        expander.opacity = 1.0;
        if (expander.parent != null)
            expander.parent.visible = true;

        var box = (Gtk.Box) expander.child;
        var node = box.get_data<Node?>("sidebar-node");
        if (node != null) {
            if (node.children_handler != 0) {
                node.children.disconnect(node.children_handler);
                node.children_handler = 0;
            }
            if (node.expanded_handler != 0) {
                var bound = list_item.get_item() as Gtk.TreeListRow;
                if (bound != null) {
                    bound.disconnect(node.expanded_handler);
                }
                node.expanded_handler = 0;
            }
            node.expander_widget = null;
            node.icon_widget = null;
            node.spinner_widget = null;
            node.name_widget = null;
            node.count_widget = null;
        }
        box.set_data<Node?>("sidebar-node", null);
    }

    private void refresh_row(Node node) {
        if (node.expander_widget == null)
            return; // not currently realised

        Sidebar.Entry entry = node.entry;
        node.expander_widget.hide_expander = (node.children.get_n_items() == 0);

        // Hide the whole list item, not just its content, so the row
        // collapses rather than leaving a gap
        Gtk.Widget row = node.expander_widget.parent ?? node.expander_widget;
        row.visible = (!this.drag_active || entry_accepts_drop(entry));

        // A busy entry swaps its icon for a spinner and dims itself
        bool busy = entry.is_busy();
        node.spinner_widget.visible = busy;
        node.spinner_widget.spinning = busy;
        if (busy) {
            node.expander_widget.add_css_class("dim-label");
        } else {
            node.expander_widget.remove_css_class("dim-label");
        }

        string? icon = entry.get_sidebar_icon();
        node.icon_widget.visible = (
            !busy && !(entry is Sidebar.Header) && icon != null
        );
        node.icon_widget.icon_name = icon;

        node.name_widget.label = get_name_for_entry(entry);

        int count = entry.get_count();
        node.count_widget.visible = count > 0;
        node.count_widget.set_text(count > 0 ? count.to_string() : "");

        string? tooltip = entry.get_sidebar_tooltip();
        node.expander_widget.tooltip_markup =
            tooltip != null ? Convey.HTML.escape_markup(tooltip) : null;
    }

    private string get_name_for_entry(Sidebar.Entry entry) {
        string name = Convey.HTML.escape_markup(entry.get_sidebar_name());

        Sidebar.EmphasizableEntry? emphasizable_entry = entry as Sidebar.EmphasizableEntry;
        if (emphasizable_entry != null && emphasizable_entry.is_emphasized())
            name = "<b>%s</b>".printf(name);

        return name;
    }

    //
    // Selection and activation
    //

    public virtual bool accept_cursor_changed(Sidebar.SelectableEntry entry) {
        return true;
    }

    private Node? node_at(uint position) {
        if (position == Gtk.INVALID_LIST_POSITION)
            return null;
        var row = this.tree_model.get_row(position);
        return (row != null) ? row.get_item() as Node : null;
    }

    private void on_row_activated(uint position) {
        Node? node = node_at(position);
        if (node == null)
            return;

        Sidebar.SelectableEntry? selectable = node.entry as Sidebar.SelectableEntry;
        if (selectable != null) {
            entry_activated(selectable);
        } else {
            var row = this.tree_model.get_row(position);
            if (row != null)
                row.set_expanded(!row.get_expanded());
        }
    }

    private void on_selection_changed(uint position, uint n_items) {
        if (this.updating_selection || this.syncing_visual_selection)
            return;

        uint pos = this.selection.selected;
        Node? node = node_at(pos);

        if (node != null && node.entry is Sidebar.SelectableEntry) {
            var selectable = (Sidebar.SelectableEntry) node.entry;
            this.selected_node = node;
            if (!this.mask_entry_selected_signal) {
                if (accept_cursor_changed(selectable)) {
                    this.last_selected_position = pos;
                    entry_selected(selectable);
                    // A single click both selects and activates (activation
                    // drives e.g. narrow-mode navigation to the content pane).
                    if (this.click_selecting) {
                        entry_activated(selectable);
                        this.activated_this_click = true;
                    }
                } else {
                    // Not allowed to switch away right now; revert.
                    restore_selection();
                }
            } else {
                this.last_selected_position = pos;
            }
        } else if (pos != Gtk.INVALID_LIST_POSITION) {
            // Headers and groupings are not selectable.
            restore_selection();
        } else {
            this.selected_node = null;
        }
    }

    // Ensures the GTK list's actual selected index (and hence its native
    // :selected row styling) points at something reasonable for the
    // current logical selection: the selected entry's own row if visible,
    // otherwise the nearest collapsed ancestor hiding it. Idempotent, and
    // safe to call whenever the set of visible rows changes.
    private void sync_visual_selection() {
        uint target = Gtk.INVALID_LIST_POSITION;

        Node? node = this.selected_node;
        if (node != null) {
            target = position_of(node);
            if (target == Gtk.INVALID_LIST_POSITION) {
                // Hidden by a collapsed ancestor; walk from the root down
                // toward the selection looking for the first collapsed
                // ancestor -- that's the row hiding it, so represent the
                // selection there instead.
                var chain = new Gee.ArrayList<Node>();
                for (Node? n = node.parent; n != null; n = n.parent)
                    chain.insert(0, n);

                foreach (Node ancestor in chain) {
                    uint apos = position_of(ancestor);
                    if (apos == Gtk.INVALID_LIST_POSITION)
                        break; // ancestor itself not visible; shouldn't happen

                    var row = this.tree_model.get_row(apos);
                    if (row != null && !row.get_expanded()) {
                        target = apos;
                        break;
                    }
                }
            }
        }

        // Keep last_selected_position (what restore_selection() reverts a
        // rejected click to) in sync with whatever row is currently
        // standing in for the selection -- otherwise clicking some other,
        // unrelated non-selectable row would revert the visible selection
        // to a stale, since-hidden position instead of this one.
        this.last_selected_position = target;

        if (this.selection.selected == target)
            return;

        this.syncing_visual_selection = true;
        this.selection.selected = target;
        this.syncing_visual_selection = false;
    }

    private void restore_selection() {
        this.updating_selection = true;
        this.selection.selected = this.last_selected_position;
        this.updating_selection = false;
    }

    // Note that this method will result in the "entry-selected" signal to
    // fire if mask_signal is set to false.
    public bool place_cursor(Sidebar.Entry entry, bool mask_signal) {
        Node? node = node_map.get(entry);
        if (node == null)
            return false;

        expand_ancestors(node);

        uint pos = position_of(node);
        if (pos == Gtk.INVALID_LIST_POSITION)
            return false;

        this.mask_entry_selected_signal = mask_signal;
        this.selection.selected = pos;
        this.mask_entry_selected_signal = false;

        this.last_selected_position = pos;
        this.selected_node = node;
        this.cursor_node = node;
        queue_focus_cursor_row();

        this.list_view.scroll_to(pos, Gtk.ListScrollFlags.NONE, null);
        if (pos == 0) {
            // scroll_to only guarantees the item is visible, not that it's
            // flush with the top edge; force that explicitly for the top
            // item (e.g. selecting the top folder on startup).
            var vadj = this.list_view.vadjustment;
            if (vadj != null)
                vadj.value = vadj.lower;
        }
        return true;
    }

    public bool is_selected(Sidebar.Entry entry) {
        // Compare against the logical selection, not the GTK list's raw
        // selected index: that index may currently point at a collapsed
        // ancestor standing in for a hidden selection (see
        // sync_visual_selection), not at entry's own row.
        return this.selected_node != null && this.selected_node.entry == entry;
    }

    public bool is_any_selected() {
        return this.selected_node != null;
    }

    public void clear_selection() {
        this.updating_selection = true;
        this.selection.selected = Gtk.INVALID_LIST_POSITION;
        this.updating_selection = false;
        this.selected_node = null;
        this.last_selected_position = Gtk.INVALID_LIST_POSITION;
        this.cursor_node = null;
    }

    // Single-click activation is handled by the primary click gesture, not
    // GtkListView's single-click-activate (which would select on hover).
    public void set_activate_on_single_click(bool single) {
        this.list_view.single_click_activate = false;
    }

    private void on_primary_pressed(int n_press, double x, double y) {
        Node? clicked = node_at_position(y);
        if (clicked != null)
            this.cursor_node = clicked;
        this.click_selecting = true;
        this.activated_this_click = false;
    }

    private void on_primary_released(int n_press, double x, double y) {
        if (this.click_selecting && !this.activated_this_click) {
            Node? node = node_at_position(y);
            if (node != null && node.entry is Sidebar.SelectableEntry &&
                this.selected_node == node) {
                // Re-click on the already-selected entry: the selection
                // didn't change so on_selection_changed didn't fire; re-emit
                // so the view can respond (e.g. scroll back to the top).
                var selectable = (Sidebar.SelectableEntry) node.entry;
                entry_selected(selectable);
                entry_activated(selectable);
            } else if (node != null && !(node.entry is Sidebar.SelectableEntry)) {
                // Clicking a header/grouping row toggles its expansion,
                // except if the click was on the expander icon.
                var picked = this.list_view.pick(x, y, Gtk.PickFlags.DEFAULT);
                var content = (node.expander_widget != null)
                    ? node.expander_widget.child : null;
                var arrow_clicked = (content == null || 
                    (picked != content && !picked.is_ancestor(content))) &&
                    picked != null &&
                    picked != node.expander_widget;
                uint pos = position_of(node);
                if (pos != Gtk.INVALID_LIST_POSITION && !arrow_clicked) {
                    var row = this.tree_model.get_row(pos);
                    if (row != null)
                        row.set_expanded(!row.get_expanded());
                }
            }
        }
        this.click_selecting = false;
    }

    //
    // Expansion and scrolling
    //

    private uint position_of(Node node) {
        uint n = this.tree_model.get_n_items();
        for (uint i = 0; i < n; i++) {
            var row = this.tree_model.get_row(i);
            if (row != null && row.get_item() == node)
                return i;
        }
        return Gtk.INVALID_LIST_POSITION;
    }

    // Expands every ancestor of node so that node itself becomes visible.
    private void expand_ancestors(Node node) {
        var chain = new Gee.ArrayList<Node>();
        for (Node? n = node.parent; n != null; n = n.parent)
            chain.insert(0, n);

        without_expansion_signal(() => {
            foreach (Node ancestor in chain) {
                uint pos = position_of(ancestor);
                if (pos != Gtk.INVALID_LIST_POSITION) {
                    var row = this.tree_model.get_row(pos);
                    if (row != null)
                        row.set_expanded(true);
                }
            }
        });
    }

    public bool expand_to_entry(Sidebar.Entry entry) {
        Node? node = node_map.get(entry);
        if (node == null)
            return false;

        expand_ancestors(node);

        uint pos = position_of(node);
        if (pos != Gtk.INVALID_LIST_POSITION) {
            var row = this.tree_model.get_row(pos);
            if (row != null) {
                without_expansion_signal(() => row.set_expanded(true));
            }
        }
        return true;
    }

    public void expand_to_first_child(Sidebar.Entry entry) {
        Node? node = node_map.get(entry);
        if (node == null)
            return;

        expand_ancestors(node);

        without_expansion_signal(() => {
            for (Node? cur = node; cur != null && cur.children.get_n_items() > 0;) {
                uint pos = position_of(cur);
                if (pos == Gtk.INVALID_LIST_POSITION)
                    break;
                var row = this.tree_model.get_row(pos);
                if (row == null)
                    break;
                row.set_expanded(true);
                cur = (Node) cur.children.get_item(0);
            }
        });
    }

    public bool scroll_to_entry(Sidebar.Entry entry) {
        Node? node = node_map.get(entry);
        if (node == null)
            return false;

        uint pos = position_of(node);
        if (pos == Gtk.INVALID_LIST_POSITION)
            return false;

        this.list_view.scroll_to(pos, Gtk.ListScrollFlags.NONE, null);
        return true;
    }

    public void scroll_to_top() {
        var vadj = this.list_view.vadjustment;
        if (vadj != null)
            vadj.value = vadj.lower;
    }

    //
    // Branch bookkeeping
    //

    public bool has_branch(Sidebar.Branch branch) {
        return branches.has_key(branch);
    }

    public void graft(Sidebar.Branch branch, int position) {
        assert(!branches.has_key(branch));

        branches.set(branch, position);

        if (branch.get_show_branch()) {
            associate_branch(branch);

            if (branch.is_startup_expand_to_first_child())
                expand_to_first_child(branch.get_root());

            if (branch.is_startup_open_grouping())
                expand_to_entry(branch.get_root());
        }

        branch.entry_added.connect(on_branch_entry_added);
        branch.entry_removed.connect(on_branch_entry_removed);
        branch.entry_moved.connect(on_branch_entry_moved);
        branch.entry_reparented.connect(on_branch_entry_reparented);
        branch.children_reordered.connect(on_branch_children_reordered);
        branch.show_branch.connect(on_show_branch);

        branch_added(branch);
    }

    public int get_position_for_branch(Sidebar.Branch branch) {
        if (branches.has_key(branch))
            return branches.get(branch);

        return int.MIN;
    }

    public void prune(Sidebar.Branch branch) {
        assert(branches.has_key(branch));

        if (node_map.has_key(branch.get_root()))
            disassociate_branch(branch);

        branch.entry_added.disconnect(on_branch_entry_added);
        branch.entry_removed.disconnect(on_branch_entry_removed);
        branch.entry_moved.disconnect(on_branch_entry_moved);
        branch.entry_reparented.disconnect(on_branch_entry_reparented);
        branch.children_reordered.disconnect(on_branch_children_reordered);
        branch.show_branch.disconnect(on_show_branch);

        bool removed = branches.unset(branch);
        assert(removed);

        branch_removed(branch);
    }

    protected void prune_all() {
        while (branches.keys.size > 0) {
            Gee.Iterator<Sidebar.Branch> iterator = branches.keys.iterator();
            if (!iterator.next())
                break;

            prune(iterator.get());
        }
    }

    private void associate_branch(Sidebar.Branch branch) {
        assert(branches.has_key(branch));

        int position = branches.get(branch);

        var root_node = new Node(branch.get_root(), null);
        root_node.root_position = position;

        // Insert before the first existing root with a greater position.
        uint index = this.roots.get_n_items();
        for (uint i = 0; i < this.roots.get_n_items(); i++) {
            var existing = (Node) this.roots.get_item(i);
            if (position < existing.root_position) {
                index = i;
                break;
            }
        }
        this.roots.insert(index, root_node);
        register_node(root_node);

        associate_children(branch, branch.get_root(), root_node);
    }

    private void associate_children(Sidebar.Branch branch, Sidebar.Entry parent,
                                    Node parent_node) {
        Gee.List<Sidebar.Entry>? children = branch.get_children(parent);
        if (children == null)
            return;

        foreach (Sidebar.Entry child in children) {
            var child_node = new Node(child, parent_node);
            parent_node.children.append(child_node);
            register_node(child_node);
            associate_children(branch, child, child_node);
        }
    }

    private void register_node(Node node) {
        // An entry can be re-grafted while its previous node is still
        // fading out (eg. a group emptied and immediately refilled by a
        // rename); drop the old node now rather than tripping over it.
        Node? stale = node_map.get(node.entry);
        if (stale != null)
            unregister_subtree(stale, true);

        assert(!node_map.has_key(node.entry));
        node_map.set(node.entry, node);

        node.entry.entry_changed.connect(on_entry_changed);
        node.entry.grafted(this);
    }

    private void disassociate_branch(Sidebar.Branch branch) {
        Node? root_node = node_map.get(branch.get_root());
        if (root_node != null)
            unregister_subtree(root_node, true);
    }

    // Removes node (optionally detaching it from its parent store) along
    // with its whole subtree, firing selected-entry-removed if the
    // currently-selected entry is pruned.
    private void unregister_subtree(Node node, bool remove_from_parent) {
        // A pending fade-out can race the branch being torn down, or the
        // entry being re-grafted; either way, only remove the node once
        if (node.unregistered)
            return;
        node.unregistered = true;

        bool selected = is_selected(node.entry);

        bool was_suppressed = this.suppress_expansion_signal;
        this.suppress_expansion_signal = true;
        while (node.children.get_n_items() > 0) {
            var child = (Node) node.children.get_item(0);
            unregister_subtree(child, false);
            node.children.remove(0);
        }

        if (remove_from_parent) {
            GLib.ListStore parent_store =
                (node.parent != null) ? node.parent.children : this.roots;
            uint index;
            if (parent_store.find(node, out index))
                parent_store.remove(index);
        }
        this.suppress_expansion_signal = was_suppressed;

        if (this.selected_node == node)
            this.selected_node = null;
        if (this.cursor_node == node)
            this.cursor_node = null;

        Sidebar.Entry entry = node.entry;
        entry.pruned(this);
        entry.entry_changed.disconnect(on_entry_changed);
        node_map.unset(entry);

        if (selected) {
            Sidebar.SelectableEntry? selectable = entry as Sidebar.SelectableEntry;
            if (selectable != null)
                selected_entry_removed(selectable);
        }
    }

    //
    // Branch signal handlers
    //

    private void on_branch_entry_added(Sidebar.Branch branch, Sidebar.Entry entry) {
        Sidebar.Entry? parent = branch.get_parent(entry);
        assert(parent != null);

        Node? parent_node = node_map.get(parent);
        assert(parent_node != null);

        var node = new Node(entry, parent_node);

        uint index = parent_node.children.get_n_items();
        Sidebar.Entry? next = branch.get_next_sibling(entry);
        if (next != null) {
            Node? next_node = node_map.get(next);
            uint next_index = 0;
            if (next_node != null && parent_node.children.find(next_node, out next_index))
                index = next_index;
        }
        node.fade_in = !branch.suppress_animation;
        parent_node.children.insert(index, node);
        register_node(node);
        associate_children(branch, entry, node);

        if ((branch.is_auto_open_on_new_child() ||
             parent is Sidebar.Grouping) &&
            !user_collapsed_ancestor(node)) {
            expand_to_entry(entry);
        }
    }

    // Determines if any ancestor of node was left collapsed by the user.
    private bool user_collapsed_ancestor(Node node) {
        for (Node? parent = node.parent; parent != null; parent = parent.parent) {
            if (is_collapsed(parent.entry)) {
                return true;
            }
        }
        return false;
    }

    private void on_branch_entry_removed(Sidebar.Branch branch, Sidebar.Entry entry) {
        Node? node = node_map.get(entry);
        if (node == null || node.fading_out)
            return;

        if (branch.suppress_animation) {
            unregister_subtree(node, true);
            return;
        }

        // Keep the row in the model until it has faded out, so the
        // removal is visible rather than instant.
        node.fading_out = true;
        fade_row(node, 1.0, 0.0, (value) => unregister_subtree(node, true));
    }

    private void on_branch_entry_moved(Sidebar.Branch branch, Sidebar.Entry entry) {
        Node? node = node_map.get(entry);
        assert(node != null);

        GLib.ListStore parent_store =
            (node.parent != null) ? node.parent.children : this.roots;

        Sidebar.Entry? prev = branch.get_previous_sibling(entry);
        Node? prev_node = (prev != null) ? node_map.get(prev) : null;
        reposition(parent_store, node, prev_node);
    }

    private void on_branch_entry_reparented(Sidebar.Branch branch, Sidebar.Entry entry,
                                            Sidebar.Entry old_parent) {
        Node? node = node_map.get(entry);
        assert(node != null);

        bool was_selected = is_selected(entry);

        // Detach from the current parent store.
        GLib.ListStore old_store =
            (node.parent != null) ? node.parent.children : this.roots;
        uint old_index;
        if (old_store.find(node, out old_index))
            old_store.remove(old_index);

        Sidebar.Entry? parent = branch.get_parent(entry);
        assert(parent != null);
        Node? parent_node = node_map.get(parent);
        assert(parent_node != null);
        node.parent = parent_node;

        Sidebar.Entry? prev = branch.get_previous_sibling(entry);
        Node? prev_node = (prev != null) ? node_map.get(prev) : null;
        uint index = 0;
        if (prev_node != null) {
            uint prev_index;
            if (parent_node.children.find(prev_node, out prev_index))
                index = prev_index + 1;
        }
        parent_node.children.insert(index, node);

        if (was_selected) {
            expand_to_entry(entry);
            place_cursor(entry, false);
        }
    }

    private void on_branch_children_reordered(Sidebar.Branch branch, Sidebar.Entry entry) {
        Gee.List<Sidebar.Entry>? children = branch.get_children(entry);
        if (children == null)
            return;

        Node? parent_node = node_map.get(entry);
        if (parent_node == null)
            return;

        Node? after = null;
        foreach (Sidebar.Entry child in children) {
            Node? child_node = node_map.get(child);
            if (child_node == null)
                continue;
            reposition(parent_node.children, child_node, after);
            after = child_node;
        }
    }

    private void on_show_branch(Sidebar.Branch branch, bool shown) {
        if (shown)
            associate_branch(branch);
        else
            disassociate_branch(branch);

        branch_shown(branch, shown);
    }

    private void on_entry_changed(Sidebar.Entry entry) {
        Node? node = node_map.get(entry);
        if (node != null)
            refresh_row(node);
    }

    // Moves node so it immediately follows "after" (or to the head of the
    // store when after is null), within the given store.
    private void reposition(GLib.ListStore store, Node node, Node? after) {
        uint current;
        if (!store.find(node, out current))
            return;
        store.remove(current);

        uint index = 0;
        if (after != null) {
            uint after_index;
            if (store.find(after, out after_index))
                index = after_index + 1;
        }
        store.insert(index, node);
    }

    //
    // Editing (inline rename)
    //

    public void disable_editing() {
        this.editing_disabled++;
    }

    public void enable_editing() {
        if (this.editing_disabled > 0)
            this.editing_disabled--;
    }

    public bool rename_entry_in_place(Sidebar.Entry entry) {
        if (!expand_to_entry(entry))
            return false;
        if (!place_cursor(entry, false))
            return false;

        return rename_in_place();
    }

    private bool rename_in_place() {
        if (this.editing_disabled > 0)
            return false;

        Node? node = this.selected_node;
        if (node == null || node.name_widget == null)
            return false;

        Sidebar.RenameableEntry? renameable = node.entry as Sidebar.RenameableEntry;
        if (renameable == null || !renameable.is_user_renameable())
            return false;
        if (node.entry is Sidebar.Grouping)
            return false;

        Gtk.Label label = node.name_widget;
        var box = label.get_parent() as Gtk.Box;
        if (box == null)
            return false;

        var editor = new Gtk.Text() {
            text = node.entry.get_sidebar_name(),
            hexpand = true
        };
        label.visible = false;
        box.insert_child_after(editor, label);
        // Deferred: when renaming from the context menu, the popover is
        // still closing and would take the focus straight back
        GLib.Idle.add(() => {
            editor.grab_focus();
            editor.select_region(0, -1);
            return GLib.Source.REMOVE;
        });

        editor.activate.connect(() => {
            renameable.rename(editor.text);
            finish_rename(editor, label);
        });
        var focus = new Gtk.EventControllerFocus();
        focus.leave.connect(() => finish_rename(editor, label));
        editor.add_controller(focus);

        return true;
    }

    private void finish_rename(Gtk.Text editor, Gtk.Label label) {
        var box = editor.get_parent() as Gtk.Box;
        if (box != null)
            box.remove(editor);
        label.visible = true;
    }

    //
    // Input
    //

    // Where the keyboard cursor is, falling back to the selection.
    private uint cursor_or_selection() {
        uint n = this.tree_model.get_n_items();
        if (this.cursor_node != null) {
            uint pos = position_of(this.cursor_node);
            if (pos != Gtk.INVALID_LIST_POSITION)
                return pos;
        }
        if (this.selection.selected != Gtk.INVALID_LIST_POSITION &&
            this.selection.selected < n)
            return this.selection.selected;
        return (n > 0) ? 0 : Gtk.INVALID_LIST_POSITION;
    }

    private bool move_cursor_to(uint pos) {
        uint n = this.tree_model.get_n_items();
        if (n == 0)
            return true;
        if (pos == Gtk.INVALID_LIST_POSITION || pos >= n)
            pos = n - 1;

        Node? at = node_at(pos);
        this.cursor_node = at;
        this.list_view.scroll_to(pos, Gtk.ListScrollFlags.FOCUS, null);
        // scroll_to() grabs the focus programmatically, which doesn't by
        // itself put the window into keyboard-navigation mode, so the row
        // would get no focus ring.
        var window = get_root() as Gtk.Window;
        if (window != null)
            window.set_focus_visible(true);
        return true;
    }

    // Commits the cursor row: selects and activates it, or toggles a
    // header/grouping row's expansion.
    private bool activate_cursor() {
        uint pos = cursor_or_selection();
        Node? node = node_at(pos);
        if (node == null)
            return false;

        var selectable = node.entry as Sidebar.SelectableEntry;
        if (selectable == null) {
            var row = this.tree_model.get_row(pos);
            if (row != null)
                row.set_expanded(!row.get_expanded());
            return true;
        }

        if (this.selection.selected != pos) {
            this.selection.selected = pos;
        } else {
            // Selection didn't change, so on_selection_changed didn't fire.
            entry_selected(selectable);
        }
        entry_activated(selectable);
        return true;
    }

    private bool on_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
        // Leave the inline rename editor alone -- it wants the cursor keys.
        var root = get_root() as Gtk.Root;
        if (root != null && root.get_focus() is Gtk.Editable)
            return false;

        if ((state & (Gdk.ModifierType.CONTROL_MASK |
                      Gdk.ModifierType.ALT_MASK)) == 0) {
            uint cursor = cursor_or_selection();
            uint page = 10;
            switch (keyval) {
                case Gdk.Key.Up:
                case Gdk.Key.KP_Up:
                    return move_cursor_to(
                        (cursor > 0 && cursor != Gtk.INVALID_LIST_POSITION)
                            ? cursor - 1 : 0
                    );

                case Gdk.Key.Down:
                case Gdk.Key.KP_Down:
                    return move_cursor_to(
                        (cursor == Gtk.INVALID_LIST_POSITION) ? 0 : cursor + 1
                    );

                case Gdk.Key.Page_Up:
                case Gdk.Key.KP_Page_Up:
                    return move_cursor_to(
                        (cursor > page && cursor != Gtk.INVALID_LIST_POSITION)
                            ? cursor - page : 0
                    );

                case Gdk.Key.Page_Down:
                case Gdk.Key.KP_Page_Down:
                    return move_cursor_to(
                        (cursor == Gtk.INVALID_LIST_POSITION) ? 0 : cursor + page
                    );

                case Gdk.Key.Home:
                case Gdk.Key.KP_Home:
                    return move_cursor_to(0);

                case Gdk.Key.End:
                case Gdk.Key.KP_End:
                    return move_cursor_to(Gtk.INVALID_LIST_POSITION);

                case Gdk.Key.Return:
                case Gdk.Key.ISO_Enter:
                case Gdk.Key.KP_Enter:
                case Gdk.Key.space:
                case Gdk.Key.KP_Space:
                    return activate_cursor();
            }
        }

        switch (Gdk.keyval_name(keyval)) {
            case "F2":
                return rename_in_place();

            case "Delete":
                Node? node = this.selected_node;
                if (node != null) {
                    Sidebar.DestroyableEntry? destroyable =
                        node.entry as Sidebar.DestroyableEntry;
                    if (destroyable != null) {
                        destroyable.destroy_source();
                        return true;
                    }
                }
                return false;
        }
        return false;
    }

    private void on_secondary_press(int n_press, double x, double y) {
        // Blank space past the end of a row, or below the last one,
        // belongs to whatever row starts above it
        this.context_node = node_at_position(y, true);

        // Emitted first so handlers can swap in the menu they want
        context_menu_requested(this.context_entry);

        Gtk.PopoverMenu? menu = get_context_menu(this.context_entry);
        if (menu == null)
            return;

        Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
        menu.set_pointing_to(rect);
        menu.popup();
    }

    /**
     * The node whose row is at the given vertical position.
     *
     * Resolved by row rather than by picking the widget under the
     * pointer: a row's content box needn't span its full width, so a
     * click to the right of the label lands on the row container. If
     * `nearest` is set, a position past the end of the rows resolves to
     * the last row starting above it rather than to null.
     */
    private Node? node_at_position(double y, bool nearest = false) {
        Node? found = null;
        for (Gtk.Widget? row = this.list_view.get_first_child();
             row != null;
             row = row.get_next_sibling()) {
            Graphene.Rect bounds;
            if (!row.compute_bounds(this.list_view, out bounds))
                continue;
            if (bounds.origin.y > y)
                continue;

            Node? node = node_in_row(row);
            if (node == null)
                continue;

            if (y < bounds.origin.y + bounds.size.height)
                return node;
            if (nearest)
                found = node;
        }
        return found;
    }

    private Node? node_in_row(Gtk.Widget widget) {
        var box = widget as Gtk.Box;
        if (box != null) {
            Node? node = box.get_data<Node?>("sidebar-node");
            if (node != null)
                return node;
        }

        for (Gtk.Widget? child = widget.get_first_child();
             child != null;
             child = child.get_next_sibling()) {
            Node? node = node_in_row(child);
            if (node != null)
                return node;
        }
        return null;
    }

    private bool on_drop_target_drop(Gtk.DropTarget drop_target,
                                     GLib.Value value,
                                     double x, double y) {
        if (!value.holds(typeof(string)) ||
            value.get_string() != "application/x-convey-mail") {
            return false;
        }

        Node? node = node_at_position(y);
        Sidebar.InternalDropTargetEntry? entry = (node != null)
            ? node.entry as Sidebar.InternalDropTargetEntry : null;
        if (entry == null)
            return false;

        Gdk.Drop? drop = drop_target.get_current_drop();
        Gdk.DragAction possible = (drop != null)
            ? drop.actions : Gdk.DragAction.MOVE;
        Gdk.DragAction action = ((possible & Gdk.DragAction.MOVE) != 0)
            ? Gdk.DragAction.MOVE : Gdk.DragAction.COPY;
        return entry.internal_drop_received(this, action);
    }
}
