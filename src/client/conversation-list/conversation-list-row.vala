/*
 * Copyright © 2022 John Renner <john@jrenner.net>
 * Copyright © 2022 Cédric Bellegarde <cedric.bellegarde@adishatz.org>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */


/**
 * A conversation list row displaying an email summary
 */
[GtkTemplate (ui = "/net/donnybeelo/Convey/conversation-list-row.ui")]
internal class ConversationList.Row : Gtk.ListBoxRow {

    private Gee.List<Convey.RFC822.MailboxAddress>? user_accounts  {
        owned get {
            return conversation.base_folder.account.information.sender_mailboxes;
        }
    }

    [GtkChild] unowned Gtk.Box details;
    [GtkChild] unowned Gtk.Box preview_box;
    [GtkChild] unowned Gtk.Box participants_box;
    [GtkChild] unowned Gtk.Box subject_box;
    [GtkChild] unowned Gtk.Image encrypted_icon;
    [GtkChild] unowned Gtk.Label preview;
    [GtkChild] unowned Gtk.Label subject;
    [GtkChild] unowned Gtk.Label participants;
    [GtkChild] unowned Gtk.Label date;
    [GtkChild] unowned CountBadge count_badge;

    [GtkChild] unowned Gtk.Image flagged_icon;

    [GtkChild] unowned Gtk.CheckButton selected_button;
    [GtkChild] unowned Gtk.Revealer selected_revealer;

    static construct {
        typeof(CountBadge).ensure();
    }

    private Gtk.Revealer revealer = new Gtk.Revealer() {
        transition_type = SLIDE_DOWN,
        transition_duration = ANIMATION_DURATION_MS
    };

    internal const uint ANIMATION_DURATION_MS = 250;
    private const uint DIVIDER_DELAY_MS = 20;

    internal string[] field_order {
        set {
            Gtk.Widget? previous = null;
            foreach (string field in value) {
                Gtk.Widget? widget = get_field_widget(field);
                if (widget != null) {
                    this.details.reorder_child_after(widget, previous);
                    previous = widget;
                }
            }
            place_count_badge();
        }
    }

    internal bool leaving { get; private set; default = false; }
    internal bool entering { get; private set; default = false; }

    private Adw.TimedAnimation? fade_animation = null;

    internal Convey.App.Conversation conversation;
    private Application.Configuration config;
    private Application.DecryptedSubjects decrypted_subjects;
    private DateTime? recv_time;

    internal signal void toggle_flag(ConversationList.Row row,
                                     Convey.NamedFlag flag);
    internal signal void toggle_selection(ConversationList.Row row,
                                          bool active);

    internal Row(Application.Configuration config,
                 Application.DecryptedSubjects decrypted_subjects,
                 Convey.App.Conversation conversation,
                 bool selection_mode_enabled) {
        this.config = config;
        this.decrypted_subjects = decrypted_subjects;
        this.conversation = conversation;

        Gtk.Widget content = this.child;
        this.child = this.revealer;
        this.revealer.child = content;
        this.revealer.notify["child-revealed"].connect(() => {
            if (this.revealer.child_revealed && this.entering) {
                GLib.Timeout.add(DIVIDER_DELAY_MS, () => {
                    this.entering = false;
                    return GLib.Source.REMOVE;
                });
            }
        });

        conversation.email_flags_changed.connect(update_flags);

        this.participants_box.notify["visible"].connect(place_count_badge);
        this.subject_box.notify["visible"].connect(place_count_badge);
        this.preview_box.notify["visible"].connect(place_count_badge);

        config.bind(Application.Configuration.DISPLAY_PREVIEW_KEY,
                    this.preview_box, "visible");
        config.bind(Application.Configuration.DISPLAY_PARTICIPANTS_KEY,
                    this.participants_box, "visible");
        config.bind(Application.Configuration.DISPLAY_SUBJECT_KEY,
                    this.subject_box, "visible");
        config.bind(Application.Configuration.CONVERSATION_LIST_ORDER_KEY,
                    this, "field-order", GET);

        if (selection_mode_enabled) {
            set_selection_enabled(true);
        }

        update();
    }

    public override bool focus(Gtk.DirectionType direction) {
        if (!this.config.autoselect && !this.has_focus && get_focus_child() == null) {
            return grab_focus();
        }
        return base.focus(direction);
    }

    /** Shows the row immediately, without animating. */
    internal void show_now() {
        this.revealer.transition_type = NONE;
        this.revealer.reveal_child = true;
        this.revealer.transition_type = SLIDE_DOWN;
    }

    /** Glides the row open once it is on screen. */
    internal void animate_in() {
        this.entering = true;
        this.opacity = 0;
        if (get_mapped()) {
            reveal();
            return;
        }
        ulong id = 0;
        id = this.map.connect(() => {
            disconnect(id);
            if (!this.leaving) {
                reveal();
            }
        });
    }

    private void reveal() {
        fade(1);
        this.revealer.reveal_child = true;
    }

    /** Fades the row out while gliding it closed. */
    internal void animate_out() {
        this.leaving = true;
        get_header()?.add_css_class("hidden-divider");
        fade(0);
        this.revealer.reveal_child = false;
    }

    private void fade(double to) {
        if (this.fade_animation != null) {
            this.fade_animation.pause();
        }
        var target = new Adw.PropertyAnimationTarget(this, "opacity");
        this.fade_animation = new Adw.TimedAnimation(
            this, this.opacity, to, ANIMATION_DURATION_MS, target
        );
        this.fade_animation.play();
    }

    internal void update() {
        Convey.Email? last_email = conversation.get_latest_recv_email(
            Convey.App.Conversation.Location.IN_FOLDER_OUT_OF_FOLDER
        );

        if (last_email != null) {
            this.subject.set_text(
                this.decrypted_subjects.get_display_subject(last_email)
            );
            bool encrypted = last_email.preview != null && last_email.preview.is_encrypted;
            this.encrypted_icon.visible = encrypted;
            if (encrypted) {
                if (last_email.preview.is_inline_encrypted) {
                    this.encrypted_icon.icon_name = "dialog-password-symbolic";
                    this.encrypted_icon.tooltip_text = _("Encrypted with inline PGP");
                } else {
                    this.encrypted_icon.icon_name = "channel-secure-symbolic";
                    this.encrypted_icon.tooltip_text = null;
                }
                this.preview.set_text(_("Encrypted message"));
                this.preview.add_css_class("encrypted");
            } else {
                this.preview.set_text(
                    Convey.String.reduce_whitespace(last_email.get_preview_as_string())
                );
                this.preview.remove_css_class("encrypted");
            }
            if (last_email.properties != null) {
                this.recv_time = last_email.properties.date_received.to_local();
                refresh_time();
            }
        }

        this.participants.set_markup(get_participants());

        var count = conversation.get_count();
        if (count > 1) {
            this.count_badge.set_text(conversation.get_count().to_string());
        } else {
            this.count_badge.hide();
        }

        update_flags(null);

    }

    internal void set_selection_enabled(bool enabled, bool animate = true) {
        if (!animate) {
            this.selected_revealer.transition_type = NONE;
        }
        if (enabled) {
            set_button_active(this.is_selected());
            this.state_flags_changed.connect(update_button);
            this.selected_button.toggled.connect(update_state_flags);
            this.selected_revealer.reveal_child = true;
        } else {
            this.state_flags_changed.disconnect(update_button);
            this.selected_button.toggled.disconnect(update_state_flags);
            set_button_active(false);
            this.selected_revealer.reveal_child = false;
        }
        this.selected_revealer.transition_type = SLIDE_RIGHT;
    }

    internal void refresh_time() {
        if (this.recv_time != null) {
            // conversation list store sorts by date-received, so display that
            // instead of the sent time
            this.date.set_text(Util.Date.pretty_print(
                this.recv_time,
                this.config.clock_format
            ));
        }
    }

    private void set_button_active(bool active) {
        this.selected_button.set_active(active);
        if (active) {
            this.add_css_class("selected");
            this.set_state_flags(Gtk.StateFlags.SELECTED, false);
        } else {
            this.remove_css_class("selected");
            this.unset_state_flags(Gtk.StateFlags.SELECTED);
        }
    }
    private void update_button() {
        bool is_selected = (Gtk.StateFlags.SELECTED in this.get_state_flags());

        this.selected_button.toggled.disconnect(update_state_flags);
        set_button_active(is_selected);
        this.selected_button.toggled.connect(update_state_flags);

    }

    private void update_state_flags() {
        this.state_flags_changed.disconnect(update_button);
        toggle_selection(this, this.selected_button.get_active());
        this.state_flags_changed.connect(update_button);
    }

    private void update_flags(Convey.Email? email) {
        if (conversation.is_unread()) {
            add_css_class("unread");
        } else {
            remove_css_class("unread");
        }

        if (conversation.is_flagged()) {
            this.flagged_icon.show();
        } else {
            this.flagged_icon.hide();
        }
    }

    private void place_count_badge() {
        var line = this.details.get_first_child();
        while (line != null && !line.visible) {
            line = line.get_next_sibling();
        }
        var badge = this.count_badge;
        if (line != null && badge.parent != line) {
            badge.unparent();
            badge.insert_before(line, null);
        }
    }

    private Gtk.Widget? get_field_widget(string field) {
        switch (field) {
        case "participants":
            return this.participants_box;
        case "subject":
            return this.subject_box;
        case "preview":
            return this.preview_box;
        default:
            return null;
        }
    }

    private string get_participants() {
        var participants = new Gee.ArrayList<Participant>();
        var addresses = new Convey.RFC822.MailboxAddresses();
        Gee.List<Convey.Email> emails = conversation.get_emails(
                          Convey.App.Conversation.Ordering.RECV_DATE_ASCENDING);
        bool is_outgoing = conversation.base_folder.used_as.is_outgoing();
        foreach (Convey.Email message in emails) {
            Convey.RFC822.MailboxAddresses? addrs =
                is_outgoing
                ? message.to
                : message.from;
            if (addrs != null) {
                addresses = addresses.merge_list(addrs);
            }
        }

        Gee.List<Convey.RFC822.MailboxAddress> list = Convey.traverse(
            addresses.get_all()
        ).filter((address) => {
            // In sent, we only want to show "Me"
            if (is_outgoing && addresses.size > 1) {
                foreach (var account in this.user_accounts) {
                    if (account.equal_to(address)) {
                        return false;
                    }
                }
            }
            return true;
        }).to_array_list();

        foreach (Convey.RFC822.MailboxAddress address in list) {
            Participant participant_display = new Participant(address);
            int existing_index = participants.index_of(participant_display);
            if (existing_index < 0) {
                participants.add(participant_display);
                continue;
            }
        }

        if (participants.size == 0) {
            return "";
        }

        if(participants.size == 1) {
            return participants[0].get_full_markup(this.user_accounts);
        }

        StringBuilder builder = new StringBuilder();
        bool first = true;
        foreach (Participant participant in participants) {
            if (!first) {
                builder.append(", ");
            }

            builder.append(participant.get_short_markup(this.user_accounts));
            first = false;
        }

        return builder.str;
    }
}
