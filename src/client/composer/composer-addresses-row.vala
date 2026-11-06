/*
 * Copyright © 2016 Software Freedom Conservancy Inc.
 * Copyright © 2025 Niels De Graef <nielsdegraef@gmail.com>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * A widget that allows a user to create a list of email addresses
 * (for example a "CC" row).
 */
public class Composer.AddressesRow : Adw.EntryRow, Convey.BaseInterface {

    /**
     * The list of email addresses.
     *
     * Check the "is-valid" property to see if they are actually valid.
     *
     * Manually setting this property will override any text that was there before.
     */
    public Convey.RFC822.MailboxAddresses addresses {
        get { return this._addresses; }
        set {
            this._addresses = value;
            validate_addresses();
            this.text = value.to_full_display();
        }
    }
    private Convey.RFC822.MailboxAddresses _addresses = new Convey.RFC822.MailboxAddresses();

    /** Determines if the entry contains only valid email addresses (and is not empty) */
    public bool is_valid { get; private set; default = false; }

    public bool is_empty {
        // Check the text rather than the parsed addresses so that
        // typed-but-invalid text doesn't count as empty
        get { return Convey.String.is_empty_or_whitespace(this.text); }
    }

    // Text between the start of the entry or end of the previous email
    // address and the current position of the cursor, if any.
    // This will be used for searching a match in the contact list.
    public string search_key {
        get { return this._search_key; }
        set {
            if (this._search_key == value)
                return;
            string old_value = this._search_key;
            this._search_key = value;
            update_search_filter(old_value, value);
            notify_property("search-key");
        }
    }
    private string _search_key = "";

    // The list of (possibly incomplete) email addresses
    private GenericArray<string> addresses_raw = new GenericArray<string>();
    // Index in addressew_raw of the email address the cursor is currently at
    private int cursor_at_address = 0;

    public Application.ContactStore? contacts { get; set; default = null; }

    private unowned AddressSuggestionPopover popover;

    private Components.EntryUndo undo;

    construct {
        this.undo = new Components.EntryUndo(this);
        this.changed.connect(on_changed);

        var popover = new AddressSuggestionPopover();
        bind_property("contacts", popover, "contacts", BindingFlags.SYNC_CREATE);
        popover.selected_address.connect(on_address_suggestion_selected);
        popover.set_parent(this);
        this.popover = popover;

        // We can't use the default autohide behavior since it grabs focus,
        // which we don't want (as the user should be able to continue typing).
        popover.autohide = false;

        // Since the popover never takes focus, drive its selection from
        // the entry's key events (arrow keys to move, Enter to accept).
        var key_controller = new Gtk.EventControllerKey();
        key_controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        key_controller.key_pressed.connect(on_completion_key_pressed);
        add_controller(key_controller);

        // Only suggest while the entry has the focus, since the popover
        // doesn't autohide and would otherwise stay up.
        var focus_controller = new Gtk.EventControllerFocus();
        focus_controller.enter.connect(() => {
            this.entry_focused = true;
            if (this.is_valid && !this.text.chomp().has_suffix(",")) {
                int pos = this.text.char_count();
                insert_text(", ", -1, ref pos);
                set_position(-1);
            }
        });
        focus_controller.leave.connect(() => {
            this.entry_focused = false;
            cancel_search();
            this.popover.clear_suggestions();
            this.popover.popdown();

            string trimmed = this.text.chomp();
            if (trimmed.has_suffix(",")) {
                delete_text(trimmed.char_count() - 1, -1);
            }
        });
        add_controller(focus_controller);
    }

    private bool entry_focused = false;

    private bool on_completion_key_pressed(Gtk.EventControllerKey controller,
                                           uint keyval,
                                           uint keycode,
                                           Gdk.ModifierType state) {
        if (!this.popover.has_suggestions()) {
            return Gdk.EVENT_PROPAGATE;
        }
        switch (keyval) {
        case Gdk.Key.Down:
            this.popover.move_selection(1);
            return Gdk.EVENT_STOP;
        case Gdk.Key.Up:
            this.popover.move_selection(-1);
            return Gdk.EVENT_STOP;
        case Gdk.Key.Return:
        case Gdk.Key.KP_Enter:
        case Gdk.Key.Tab:
            this.popover.activate_selected();
            return Gdk.EVENT_STOP;
        case Gdk.Key.Escape:
            this.popover.popdown();
            return Gdk.EVENT_STOP;
        }
        return Gdk.EVENT_PROPAGATE;
    }

    public AddressesRow(string title) {
        Object(title: title);
        base_ref();
    }

    ~AddressesRow() {
        base_unref();
    }

    private void validate_addresses() {
        bool is_valid = !this._addresses.is_empty;
        foreach (Convey.RFC822.MailboxAddress address in this.addresses) {
            if (!address.is_valid()) {
                is_valid = false;
                return;
            }
        }
        this.is_valid = is_valid;
    }

    private void on_changed() {
        update_addresses();
        update_validity();
    }

    private void update_addresses() {
        string current_key = "";
        this.cursor_at_address = 0;
        this.addresses_raw.length = 0;

        // NB: Do not strip any white space from the addresses,
        // otherwise we won't be able to accurately insert
        // addresses in the middle of the list in
        // ::insert_address_at_cursor.

        int current_char = 0;
        unichar c = 0;
        int start_idx = 0;
        int next_idx = 0;
        bool in_quote = false;
        while (this.text.get_next_char(ref next_idx, out c)) {
            if (current_char == (this.text.char_count() - 1) &&
                current_char != 0) {
                if (c != ',') {
                    // Strip whitespace here though so it does not
                    // interfere with search and highlighting.
                    current_key = this.text.slice(
                        start_idx, next_idx
                    ).strip();
                }
                // We're in the middle of the address, so it
                // hasn't yet been added to the list and hence we
                // don't need to subtract 1 from its size here
                this.cursor_at_address = this.addresses_raw.length;
            }

            switch (c) {
            case ',':
                if (!in_quote) {
                    // Don't include the comma in the address
                    string address = this.text.slice(start_idx, next_idx - 1);
                    this.addresses_raw.add(address);
                    // Don't include it in the next one, either
                    start_idx = next_idx;
                }
                break;

            case '"':
                in_quote = !in_quote;
                break;
            }

            current_char++;
        }

        // Add any remaining text after the last comma
        string address = this.text.substring(start_idx);
        this.addresses_raw.add(address);

        // Update current key
        this.search_key = current_key;
    }

    private void update_validity() {
        if (Convey.String.is_empty_or_whitespace(text)) {
            this._addresses = new Convey.RFC822.MailboxAddresses();
            this.is_valid = false;
        } else {
            try {
                this._addresses =
                    new Convey.RFC822.MailboxAddresses.from_rfc822_string(text);
                this.is_valid = true;
            } catch (Convey.RFC822.Error err) {
                this._addresses = new Convey.RFC822.MailboxAddresses();
                this.is_valid = false;
            }
        }

        notify_property("addresses");
        notify_property("is-valid");
        notify_property("is-empty");
    }

    private GLib.Cancellable? search_cancellable = null;
    private bool inserting_suggestion = false;

    // Cancels any in-flight completion search so a slower earlier query
    // can't repopulate the list with stale results after a later one.
    private void cancel_search() {
        if (this.search_cancellable != null) {
            this.search_cancellable.cancel();
            this.search_cancellable = null;
        }
    }

    private void update_search_filter(string old_value, string new_value) {
        // Don't kick off a new search for the text we just inserted from
        // a selected suggestion, or the list would immediately reopen.
        if (this.contacts == null || this.inserting_suggestion)
            return;

        cancel_search();

        if (new_value.length > 0 && this.entry_focused) {
            var cancellable = new GLib.Cancellable();
            this.search_cancellable = cancellable;
            this.popover.search_contacts.begin(new_value, cancellable, (obj, res) => {
                this.popover.search_contacts.end(res);
            });
        } else {
            this.popover.clear_suggestions();
        }
    }

    private void on_address_suggestion_selected(AddressSuggestionPopover popover,
                                                Convey.RFC822.MailboxAddress address) {
        this.inserting_suggestion = true;
        insert_address_at_cursor(address);
        this.inserting_suggestion = false;

        // Close the list so it doesn't reopen matching what we inserted.
        cancel_search();
        this.popover.clear_suggestions();
        this.popover.popdown();
    }

    private void insert_address_at_cursor(Convey.RFC822.MailboxAddress mailbox) {
        // Take care to do a delete then an insert here so that
        // Component.EntryUndo can combine the two into a single
        // undoable command.

        int start_char = 0;
        if (this.cursor_at_address > 0) {
            // Address parts don't contain commas, so need to add
            // an char width for it. Don't need to worry about
            // spaces because they are preserved by
            // ::update_addresses.
            start_char++;
            for (uint i = 0; i < this.cursor_at_address; i++) {
                start_char += this.addresses_raw[i].char_count();
            }
        }
        int end_char = get_position();

        // Format and use the selected address
        string formatted = mailbox.to_full_display();
        if (this.cursor_at_address != 0) {
            // Isn't the first address, so add some whitespace to
            // pad it out
            formatted = " " + formatted;
        }
        if (get_position() >= this.text.char_count() ||
            this.addresses_raw[this.cursor_at_address].strip() !=
            this.search_key.strip()) {
            // At the end of the entry, or the address under the
            // cursor does not simply consist of the lookup key
            // (i.e. is effectively already empty otherwise), so add
            // a comma to separate this address from the next one
            formatted = formatted + ", ";
        }
        this.addresses_raw.insert(this.cursor_at_address, formatted);

        // Update the entry text
        if (start_char < end_char) {
            delete_text(start_char, end_char);
        }
        insert_text(formatted, -1, ref start_char);

        // Update the entry cursor position. The previous call
        // updates the start so just use that, but add extra space
        // for the comma and any white space at the start of the
        // next address.
        if (start_char < this.text.char_count()) {
            start_char += 2;
        }
        set_position(start_char);
    }
}

/**
 * A helper object to list not just the addresses but also their related contact
 */
public class ContactAddressItem : GLib.Object {
    public Application.Contact contact { get; construct set; }
    public Convey.RFC822.MailboxAddress address { get; construct set; }

    public ContactAddressItem(Application.Contact contact,
                              Convey.RFC822.MailboxAddress address) {
        Object(contact: contact, address: address);
    }
}

public class AddressSuggestionPopover : Gtk.Popover {

    // Minimum visibility for the contact to appear in autocompletion.
    private const Convey.Contact.Importance VISIBILITY_THRESHOLD =
        Convey.Contact.Importance.RECEIVED_FROM;

    public Application.ContactStore contacts { get; construct set; }

    private GLib.ListStore model;
    private Gtk.SingleSelection selection;
    private unowned Gtk.ListView listview;

    /**
     * Fired when the user has selected an address suggestion
     */
    public signal void selected_address(Convey.RFC822.MailboxAddress address);

    construct {
        // Present as a full-width dropdown list under the entry rather
        // than a floating bubble.
        this.has_arrow = false;
        this.position = Gtk.PositionType.BOTTOM;
        this.halign = Gtk.Align.START;
        set_offset(0, 6);
        add_css_class("menu");

        var factory = new Gtk.SignalListItemFactory();
        factory.setup.connect(on_setup_item);
        factory.bind.connect(on_bind_item);

        this.model = new GLib.ListStore(typeof(ContactAddressItem));
        this.model.items_changed.connect((model, pos, removed, added) => {
            bool is_empty = (model.get_n_items() == 0);
            bool was_empty = ((model.get_n_items() - added + removed) == 0);
            if (is_empty != was_empty) {
                if (was_empty) {
                    // Match the popover width to the entry so it reads as
                    // a list dropped down from the field.
                    var parent = get_parent();
                    if (parent != null) {
                        set_size_request(parent.get_width(), -1);
                    }
                    popup();
                } else {
                    popdown();
                }
            }
        });
        this.selection = new Gtk.SingleSelection(this.model);

        var listview = new Gtk.ListView(selection, factory);
        listview.single_click_activate = true;
        listview.tab_behavior = Gtk.ListTabBehavior.ITEM;
        listview.activate.connect(on_activate);
        listview.add_css_class("contact-completion");
        listview.can_focus = false;
        this.listview = listview;

        var sw = new Gtk.ScrolledWindow();
        sw.hscrollbar_policy = Gtk.PolicyType.NEVER;
        sw.propagate_natural_height = true;
        sw.max_content_height = 300;
        sw.child = listview;
        this.child = sw;
    }

    private void on_setup_item(Object object) {
        unowned var item = (Gtk.ListItem) object;

        // Create the row widget
        var row = new AddressSuggestionRow();
        item.child = row;

        // Moving the mouse onto a row selects it, so the keyboard
        // selection and the mouse hover share a single highlight and
        // whichever was used last wins.
        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect((x, y) => {
            this.selection.selected = item.get_position();
        });
        row.add_controller(motion);
    }

    private void on_bind_item(Object object) {
        unowned var item = (Gtk.ListItem) object;
        unowned var row = (AddressSuggestionRow) item.child;
        unowned var contact_address = (ContactAddressItem) item.item;

        row.contact_address = contact_address;
    }

    private void on_activate(Gtk.ListView listvieww,
                             uint position) {
        var contact_addr = (ContactAddressItem?) this.selection.selected_item;
        if (contact_addr == null)
            return;

        popdown();
        selected_address(contact_addr.address);
    }

    /** Whether the popover is currently showing suggestions. */
    public bool has_suggestions() {
        return this.get_visible() && this.model.get_n_items() > 0;
    }

    /** Moves the selection by the given offset (e.g. +1/-1). */
    public void move_selection(int delta) {
        uint n = this.model.get_n_items();
        if (n == 0) {
            return;
        }
        uint sel = this.selection.selected;
        int next = (sel == Gtk.INVALID_LIST_POSITION) ? 0 : (int) sel + delta;
        next = next.clamp(0, (int) n - 1);
        this.selection.selected = (uint) next;
        this.listview.scroll_to((uint) next, Gtk.ListScrollFlags.NONE, null);
    }

    /** Activates the currently selected suggestion. */
    public void activate_selected() {
        on_activate(this.listview, this.selection.selected);
    }

    public void clear_suggestions() {
        model.remove_all();
    }

    public async void search_contacts(string query,
                                      GLib.Cancellable? cancellable) {
        Gee.Collection<Application.Contact>? results = null;
        try {
            results = yield this.contacts.search(
                query,
                VISIBILITY_THRESHOLD,
                20,
                cancellable
            );
        } catch (GLib.IOError.CANCELLED err) {
            // All good
        } catch (GLib.Error err) {
            debug("Error searching contacts for completion: %s", err.message);
        }

        if (!cancellable.is_cancelled()) {
            Object[] items = {};
            if (results != null) {
                foreach (Application.Contact contact in results) {
                    for (uint i = 0; i < contact.email_addresses.get_n_items(); i++) {
                        var addr = (Convey.RFC822.MailboxAddress) contact.email_addresses.get_item(i);
                        items += new ContactAddressItem(contact, addr);
                    }
                }
            }
            model.splice(0, model.get_n_items(), items);
        }
    }
}

private class AddressSuggestionRow : Gtk.Box {

    private unowned Gtk.Label label;

    public ContactAddressItem? contact_address {
        get { return this._contact_address; }
        set {
            if (this._contact_address == value)
                return;

            update(value);
            notify_property("contact-address");
        }
    }
    private ContactAddressItem? _contact_address = null;

    construct {
        this.orientation = Gtk.Orientation.HORIZONTAL;
        this.spacing = 6;
        this.margin_top = 3;
        this.margin_bottom = 3;
        this.margin_start = 6;
        this.margin_end = 6;

        add_css_class("contact-address-list-row");

        var label = new Gtk.Label("");
        label.ellipsize = Pango.EllipsizeMode.END;
        label.valign = Gtk.Align.CENTER;
        label.halign = Gtk.Align.START;
        label.xalign = 0;
        append(label);
        this.label = label;
    }

    private void update(ContactAddressItem contact_addr) {
        this._contact_address = contact_addr;

        if (contact_addr == null) {
            this.label.label = "";
            return;
        }

        // Show the suggestion in the same "Name <email>" form it will
        // take once inserted into the field.
        string address = contact_addr.address.address;
        string name = contact_addr.contact.display_name;
        if (Convey.String.is_empty(name)) {
            this.label.label = address;
        } else {
            this.label.label = "%s <%s>".printf(name, address);
        }
    }
}
