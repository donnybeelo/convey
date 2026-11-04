/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2016 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Application logic for ConversationWebView.
 */
let ConversationPageState = function() {
    this.init.apply(this, arguments);
};

ConversationPageState.QUOTE_CONTAINER_CLASS = "convey-quote-container";
ConversationPageState.QUOTE_HIDE_CLASS = "convey-hide";

// Keep these in sync with ConversationWebView
ConversationPageState.NOT_DECEPTIVE = 0;
ConversationPageState.DECEPTIVE_HREF = 1;
ConversationPageState.DECEPTIVE_DOMAIN = 2;

ConversationPageState.prototype = {
    __proto__: PageState.prototype,
    init: function() {
        PageState.prototype.init.apply(this, []);

        this._deceptiveLinkClicked = MessageSender("deceptive_link_clicked");

        let state = this;
        document.addEventListener("click", function(e) {
            if (e.target.tagName == "A" &&
                state.linkClicked(e.target)) {
                e.preventDefault();
            }
        }, true);
        document.addEventListener("mousemove", function(e) {
            state._pointer = e;
        });
        document.addEventListener(
            "load", () => this.updatePreferredHeight(), true
        );
        window.addEventListener("load", () => this.updatePreferredHeight());
    },
    getPreferredHeight: function() {
        return Math.ceil(
            document.documentElement.getBoundingClientRect().height
        );
    },
    fitToHeight: function(maxHeight) {
        this.maxHeight = maxHeight;
        this.autoZoom();
    },
    fitPhotos: function(measure, fits) {
        let root = document.documentElement;
        let widest = 0;
        for (const img of document.images) {
            let rect = img.getBoundingClientRect();
            if (rect.width >= 120 && rect.height >= 60 &&
                rect.width <= rect.height * 2.5) {
                img.setAttribute("data-convey-photo", "");
                widest = Math.max(widest, rect.width);
            } else {
                img.removeAttribute("data-convey-photo");
            }
        }
        let setMax = (width) => root.style.setProperty(
            "--convey-photo-max", width + "px"
        );
        let low = 80;
        root.classList.add("convey-photo-fit");
        setMax(low);
        if (widest <= low || !fits(measure())) {
            root.classList.remove("convey-photo-fit");
            return measure();
        }
        let high = widest;
        while (high - low > 4) {
            let mid = (low + high) / 2;
            setMax(mid);
            if (fits(measure())) {
                low = mid;
            } else {
                high = mid;
            }
        }
        setMax(low);
        return measure();
    },
    disableScrolling: function() {
        document.documentElement.classList.add("convey-no-scroll");
    },
    autoZoom: function() {
        if (!this.isLoaded) {
            return;
        }
        let root = document.documentElement;
        let body = document.body;
        root.classList.add("convey-auto-zoom");
        root.classList.remove(
            "convey-layout", "convey-zoomed", "convey-sized", "convey-photo-fit"
        );

        let style = getComputedStyle(body);
        let rtl = style.direction == "rtl";
        let marginLeft = parseFloat(style.marginLeft) || 0;
        let marginRight = parseFloat(style.marginRight) || 0;
        let marginBottom = parseFloat(style.marginBottom) || 0;
        let viewport = root.clientWidth;
        let contentWidth = root.scrollWidth;

        let zoom = 1;
        let width = body.getBoundingClientRect().width;
        if (contentWidth > viewport) {
            width = contentWidth - (rtl ? marginRight : marginLeft);
            zoom = (viewport - 1 - marginLeft - marginRight) / width;
        }
        root.style.setProperty("--convey-layout-width", width + "px");
        root.classList.add("convey-layout");

        let contents = document.createRange();
        contents.selectNodeContents(body);
        let measure = () => Math.max(
            0,
            contents.getBoundingClientRect().bottom -
                body.getBoundingClientRect().top
        );
        let bodyHeight = measure();
        let outside = body.getBoundingClientRect().top + marginBottom;
        let fits = (height) => outside + height * zoom <= this.maxHeight;
        if (this.maxHeight && !fits(bodyHeight)) {
            bodyHeight = this.fitPhotos(measure, fits);
            if (!fits(bodyHeight)) {
                zoom = Math.min(
                    zoom,
                    Math.max(0.3, (this.maxHeight - outside) / bodyHeight)
                );
            }
        }

        if (zoom < 0.999) {
            let shift = Math.max(
                0, (viewport - marginLeft - marginRight - width * zoom) / 2
            );
            root.style.setProperty("--convey-zoom", zoom);
            root.style.setProperty(
                "--convey-shift", (rtl ? -shift : shift) + "px"
            );
            root.style.setProperty(
                "--convey-origin", rtl ? "top right" : "top left"
            );
            root.classList.add("convey-zoomed");
        } else {
            zoom = 1;
            root.classList.remove("convey-layout");
        }
        root.style.setProperty(
            "--convey-page-height",
            Math.ceil(outside + bodyHeight * zoom) + "px"
        );
        root.classList.add("convey-sized");

        // Apply styles before transitions come back
        root.offsetHeight;
        root.classList.remove("convey-auto-zoom");
    },
    updatePreferredHeight: function() {
        this.autoZoom();
        PageState.prototype.updatePreferredHeight.apply(this, []);
    },
    scrollHorizontally: function(dx) {
        let p = this._pointer;
        let el = p ? document.elementFromPoint(p.clientX, p.clientY) : null;
        for (; el; el = el.parentElement) {
            if (el.scrollWidth > el.clientWidth &&
                /auto|scroll/.test(getComputedStyle(el).overflowX)) {
                this._hTarget = el;
                this.scrollElement(el, "scrollLeft", dx);
                return;
            }
        }
        this._hTarget = document.scrollingElement;
        this.scrollElement(this._hTarget, "scrollLeft", dx);
    },
    flingHorizontally: function(vx) {
        this.fling("_hFling", this._hTarget, "scrollLeft", vx);
    },
    scrollPage: function(dx, dy) {
        if (dx) this.scrollHorizontally(dx);
        this.scrollElement(document.scrollingElement, "scrollTop", dy);
    },
    scrollElement: function(el, prop, d) {
        this._remainder = this._remainder || {};
        let total = (this._remainder[prop] || 0) + d;
        let whole = Math.trunc(total);
        this._remainder[prop] = total - whole;
        el[prop] += whole;
    },
    flingPage: function(vx, vy) {
        this.flingHorizontally(vx);
        this.fling("_vFling", document.scrollingElement, "scrollTop", vy);
    },
    // Port of GtkKineticScrolling and gtk_scrolled_window_accumulate_velocity()
    fling: function(id, el, prop, v) {
        const FRICTION = 4, FLOOR = 0.33, CEIL = 1.0, MAX = 6.0;
        let prev = this[id];
        if (prev) cancelAnimationFrame(prev.frame);
        if (!v) return;
        this[id] = null;
        if (prev && prev.velocity && (v >= 0) == (prev.velocity >= 0) &&
            Math.abs(v) >= Math.abs(prev.velocity) * FLOOR) {
            let min = prev.velocity * FLOOR, max = prev.velocity * CEIL;
            v += prev.velocity * Math.min((v - min) / (max - min), MAX);
        }
        if (!el) return;
        let from = el[prop], start = null;
        let state = this[id] = { velocity: v, frame: null };
        let step = function(t) {
            if (start == null) start = t;
            let decay = Math.exp(-FRICTION * (t - start) / 1000);
            el[prop] = from + v / FRICTION * (1 - decay);
            state.velocity = v * decay;
            if (Math.abs(state.velocity) >= 0.1) {
                state.frame = requestAnimationFrame(step);
            } else {
                state.velocity = 0;
            }
        };
        state.frame = requestAnimationFrame(step);
    },
    /**
     * Add email headers for printing
     */
    addPrintHeaders: function(headers) {
        let headerTable = document.getElementById('convey-message-headers');
        if (headerTable) headerTable.parentNode.removeChild(headerTable);

        headerTable = document.createElement('table');
        headerTable.id = 'convey-message-headers';
        for (var header in headers) {
            let row = headerTable.appendChild(document.createElement('tr'));
            let name = row.appendChild(document.createElement('th'));
            let value = row.appendChild(document.createElement('td'));
            name.textContent = header;
            value.textContent = headers[header];
        }

        document.body.insertBefore(headerTable, document.body.firstChild);
    },
    loaded: function() {
        this.updateDirection();
        this.createControllableQuotes();
        this.wrapSignature();
        this.deceptiveLinksTitle();
        this.disableMediaRules(/width/i);
        new ResizeObserver(() => this.updatePreferredHeight())
            .observe(document.body);
        PageState.prototype.loaded.apply(this, []);
    },
    /**
     * Set dir="auto" if not already set.
     *
     * This should provide a slightly better RTL experience.
     */
    updateDirection: function() {
        let dir = document.documentElement.dir;
        if (dir == null || dir.trim() == "") {
            document.documentElement.dir = "auto";
        }
    },
    /**
     * Add top level blockquotes to hide/show container.
     */
    createControllableQuotes: function() {
        let blockquoteList = document.documentElement.querySelectorAll("blockquote");
        for (let i = 0; i < blockquoteList.length; ++i) {
            let blockquote = blockquoteList.item(i);
            let nextSibling = blockquote.nextSibling;
            let parent = blockquote.parentNode;

            // Only insert into a quote container if the element is a
            // top level blockquote
            if (!ConversationPageState.isDescendantOf(blockquote, "BLOCKQUOTE")) {
                let quoteHeight = blockquote.offsetHeight;

                // Only make the quote it controllable if it is tall enough
                let isControllable = (quoteHeight > 120);

                let quoteContainer = document.createElement("DIV");
                quoteContainer.classList.add(
                    ConversationPageState.QUOTE_CONTAINER_CLASS
                );
                if (isControllable) {
                    quoteContainer.classList.add("convey-controllable");
                    quoteContainer.classList.add(
                        ConversationPageState.QUOTE_HIDE_CLASS
                    );
                }

                let quoteDiv = document.createElement("DIV");
                quoteDiv.classList.add("convey-quote");

                quoteDiv.appendChild(blockquote);
                quoteContainer.appendChild(quoteDiv);
                parent.insertBefore(quoteContainer, nextSibling);

                let containerHeight = quoteDiv.offsetHeight;

                let state = this;
                function newControllerButton(styleClass, text) {
                    let button = document.createElement("BUTTON");
                    button.classList.add("convey-button");
                    button.type = "button";
                    button.onclick = function() {
                        let hide = ConversationPageState.QUOTE_HIDE_CLASS;
                        quoteContainer.classList.toggle(hide);

                        // Update the preferred height. We calculate
                        // what the difference should be rather than
                        // getting it directly, since WK won't ever
                        // shrink the height of the HTML element.
                        let height = quoteHeight - containerHeight;
                        if (quoteContainer.classList.contains(hide)) {
                            height = state.lastPreferredHeight - height;
                        } else {
                            height = state.lastPreferredHeight + height;
                        }
                        state.updatePreferredHeight(height);
                    };
                    button.appendChild(document.createTextNode(text));

                    let container = document.createElement("DIV");
                    container.classList.add(styleClass);
                    container.appendChild(button);

                    return container;
                }

                if (isControllable) {
                    quoteContainer.appendChild(newControllerButton(
                        "convey-shower", "▼        ▼        ▼"
                    ));
                    quoteContainer.appendChild(newControllerButton(
                        "convey-hider", "▲        ▲        ▲"
                    ));
                }
            }
        }
    },
    deceptiveLinksTitle: function() {
      let pattern = /^((http|https|ftp):\/\/)/;
      let anchors = document.getElementsByTagName("a");
      for (var i = 0; i < anchors.length; i++) {
        if(pattern.test(anchors[i].title)) {
          anchors[i].title = anchors[i].href;
        }
      }
    },
    /**
     * Look for and wrap a signature.
     *
     * Most HTML signatures fall into one
     * of these designs which are handled by this method:
     *
     * 1. GMail:            <div>-- </div>$SIGNATURE
     * 2. GMail Alternate:  <div><span>-- </span></div>$SIGNATURE
     * 3. Thunderbird:      <div>-- <br>$SIGNATURE</div>
     *
     */
    wrapSignature: function() {
        let possibleSigs = document.documentElement.querySelectorAll("div,span,p");
        let i = 0;
        let sigRegex = new RegExp("^--\\s*$");
        let alternateSigRegex = new RegExp("^--\\s*(?:<br|\\R)");
        for (; i < possibleSigs.length; ++i) {
            // Get the div and check that it starts a signature block
            // and is not inside a quote.
            let div = possibleSigs.item(i);
            let innerHTML = div.innerHTML;
            if ((sigRegex.test(innerHTML) || alternateSigRegex.test(innerHTML)) &&
                !ConversationPageState.isDescendantOf(div, "BLOCKQUOTE")) {
                break;
            }
        }
        // If we have a signature, move it and all of its following
        // siblings that are not quotes inside a signature div.
        if (i < possibleSigs.length) {
            let elem = possibleSigs.item(i);
            let parent = elem.parentNode;
            let signatureContainer = document.createElement("DIV");
            signatureContainer.classList.add("convey-signature");
            do {
                // Get its sibling _before_ we move it into the signature div.
                let sibling = elem.nextSibling;
                signatureContainer.appendChild(elem);
                elem = sibling;
            } while (elem != null);
            parent.appendChild(signatureContainer);
        }
    },
    getSelectionForQuoting: function() {
        let quote = null;
        let selection = window.getSelection();
        if (!selection.isCollapsed) {
            let range = selection.getRangeAt(0);
            let ancestor = range.commonAncestorContainer;
            if (ancestor.nodeType != Node.ELEMENT_NODE) {
                ancestor = ancestor.parentNode;
            }

            // If the selection is part of a plain text message, we
            // have to stick it in an appropriately styled div, so
            // that new lines are preserved. Do a non-strict ancestor
            // check since the common ancestor may well be the plain
            // text DIV itself
            let dummy = document.createElement("DIV");
            let includeDummy = false;
            if (ConversationPageState.isDescendantOf(
                ancestor, "DIV", "plaintext", false)) {
                dummy.classList.add("plaintext");
                dummy.setAttribute("style", "white-space: break-spaces;");
                includeDummy = true;
            }
            dummy.appendChild(range.cloneContents());

            // Remove the chrome we put around quotes, leaving
            // only the blockquote element.
            let quotes = dummy.querySelectorAll(
                "." + ConversationPageState.QUOTE_CONTAINER_CLASS
            );
            for (let i = 0; i < quotes.length; i++) {
                let div = quotes.item(i);
                let blockquote = div.querySelector("blockquote");
                div.parentNode.replaceChild(blockquote, div);
            }

            quote = includeDummy ? dummy.outerHTML : dummy.innerHTML;
        }
        return quote;
    },
    getSelectionForFind: function() {
        let value = null;
        let selection = window.getSelection();

        if (selection.rangeCount > 0) {
            let range = selection.getRangeAt(0);
            value = range.toString().trim();
            if (value == "") {
                value = null;
            }
        }
        return value;
    },
    getAnchorTargetY: function(anchor) {
        let target = document.getElementById(anchor);
        if (target == null) {
            target = document.getElementsByName(anchor);
            if (target.length > 0) {
                target = target[0];
            }
        }
        if (target != null) {
            return target.getBoundingClientRect().top +
                document.documentElement.scrollTop;
        } else {
            return -1;
        }
    },
    linkClicked: function(link) {
        let cancelClick = false;
        let href = link.href;
        if (!href.startsWith("mailto:")) {
            let text = link.innerText;
            let reason = ConversationPageState.isDeceptiveText(text, href);
            if (reason != ConversationPageState.NOT_DECEPTIVE) {
                cancelClick = true;
                this._deceptiveLinkClicked({
                    reason: reason,
                    text: text,
                    href: href,
                    location: ConversationPageState.getNodeBounds(link)
                });
            }
        }

        return cancelClick;
    }
};

/**
 * Returns an [x, y, width, height] array of a node's bounds.
 */
ConversationPageState.getNodeBounds = function(node) {
    let x = 0;
    let y = 0;
    let parent = node;
    while (parent != null) {
        x += parent.offsetLeft;
        y += parent.offsetTop;
        parent = parent.offsetParent;
    }
    return {
        x: x,
        y: y,
        width: node.offsetWidth,
        height: node.offsetHeight
    };
};

/**
 * Test for URL-like `text` that leads somewhere other than `href`.
 */
ConversationPageState.isDeceptiveText = function(text, href) {
    // First, does text look like a URI? 
    let domain = new RegExp("^"
                          + "([a-z]*://)?"                             // Optional scheme
                          + "([^\\s:/#%&*@()]+\\.[^\\s:/#%&*@()\\.]+)" // Domain
                          + "(/[^\\s]*)?"                              // Optional path
                          + "$");             
    let textParts = text.match(domain);
    if (textParts == null) {
        return ConversationPageState.NOT_DECEPTIVE;
    }
    let hrefParts = href.match(domain);
    if (hrefParts == null) {
        // If href doesn't look like a URL, something is fishy, so
        // warn the user
        return ConversationPageState.DECEPTIVE_HREF;
    }

    // Second, do the top levels of the two domains match?  We
    // compare the top n levels, where n is the minimum of the
    // number of levels of the two domains.
    let textDomain = textParts[2].toLowerCase().split(".").reverse();
    let hrefDomain = hrefParts[2].toLowerCase().split(".").reverse();
    let segmentCount = Math.min(textDomain.length, hrefDomain.length);
    if (segmentCount == 0) {
        return ConversationPageState.DECEPTIVE_DOMAIN;
    }
    for (let i = 0; i < segmentCount; i++) {
        if (textDomain[i] != hrefDomain[i]) {
            return ConversationPageState.DECEPTIVE_DOMAIN;
        }
    }

    return ConversationPageState.NOT_DECEPTIVE;
};

/**
 * See if this element has an ancestor with the given tag and class.
 *
 * The value of ancestorTag must be all uppercase.
 *
 * If ancestorClass is null, no class checking is done.
 * If strict is is true, the given node will not be checked.
 */
ConversationPageState.isDescendantOf = function(node,
                                                ancestorTag,
                                                ancestorClass = null,
                                                strict = true) {
    let ancestor = strict ? node.parentNode : node;
    while (ancestor != null) {
        if (ancestor.nodeName.toUpperCase() == ancestorTag &&
            (ancestorClass == null ||
             ancestor.classList.contains(ancestorClass))) {
            return true;
        }
        ancestor = ancestor.parentNode;
    }
    return false;
};

var convey = new ConversationPageState();
