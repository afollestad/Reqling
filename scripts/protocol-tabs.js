(function () {
    // #protocols ships every panel visible and the tablist hidden, so without
    // JavaScript the screenshots stack under their names. This turns them into
    // tabs, following the WAI-ARIA tabs pattern: arrow keys, Home, and End move
    // between tabs and select as they go, and Tab leaves the tablist for the
    // shown panel.
    var tablist = document.querySelector('.protocol-tabs');
    if (!tablist) return;

    var tabs = Array.prototype.slice.call(tablist.querySelectorAll('[role="tab"]'));
    var panels = tabs.map(function (tab) {
        return document.getElementById(tab.getAttribute('aria-controls'));
    });

    function select(index, focus) {
        for (var i = 0; i < tabs.length; i++) {
            var selected = i === index;
            tabs[i].setAttribute('aria-selected', String(selected));
            tabs[i].tabIndex = selected ? 0 : -1;
            // A hidden panel's lazy screenshot never downloads until its tab is
            // chosen.
            panels[i].hidden = !selected;
        }
        if (focus) tabs[index].focus();
    }

    // The panels keep the ids of the sections they replaced, so a link to
    // #grpc, say, opens that tab.
    function indexForHash() {
        var id = window.location.hash.slice(1);
        for (var i = 0; i < panels.length; i++) {
            if (panels[i].id === id) return i;
        }
        return -1;
    }

    for (var i = 0; i < tabs.length; i++) {
        panels[i].setAttribute('role', 'tabpanel');
        panels[i].setAttribute('aria-labelledby', tabs[i].id);
        // Nothing in a panel takes focus, so the panel itself does.
        panels[i].tabIndex = 0;
    }

    tablist.addEventListener('click', function (event) {
        var index = tabs.indexOf(event.target.closest('[role="tab"]'));
        if (index >= 0) select(index, false);
    });

    tablist.addEventListener('keydown', function (event) {
        var current = tabs.indexOf(document.activeElement);
        if (current < 0) return;
        var next;
        switch (event.key) {
            case 'ArrowRight':
                next = (current + 1) % tabs.length;
                break;
            case 'ArrowLeft':
                next = (current - 1 + tabs.length) % tabs.length;
                break;
            case 'Home':
                next = 0;
                break;
            case 'End':
                next = tabs.length - 1;
                break;
            default:
                return;
        }
        event.preventDefault();
        select(next, true);
    });

    // The browser scrolls to a fragment before this runs, while the panel may
    // still be hidden, so scroll to it once it shows.
    window.addEventListener('hashchange', function () {
        var index = indexForHash();
        if (index < 0) return;
        select(index, false);
        panels[index].scrollIntoView();
    });

    // Once the shown screenshot has loaded, fetch and decode the others, so
    // switching tabs never waits on the network or a decode. Hidden panels are
    // display: none, which keeps a lazy image from ever loading; switching it
    // to eager is what fetches it, and its <picture> still picks the variant
    // for the current theme, again if the theme changes.
    var images = panels.map(function (panel) {
        return panel.querySelector('img');
    });
    var prefetched = false;

    function prefetchOthers() {
        if (prefetched) return;
        prefetched = true;
        for (var i = 0; i < images.length; i++) {
            var image = images[i];
            image.loading = 'eager';
            image.decode().catch(function () {
                /* a failed prefetch just loads again when its tab is chosen */
            });
        }
    }

    // The panel shows before the browser's own scroll to a fragment on load,
    // which then lands on it.
    var initial = indexForHash();
    select(initial >= 0 ? initial : 0, false);
    tablist.parentNode.classList.add('tabbed');
    tablist.hidden = false;

    // Only a shown panel's lazy image loads, so whichever loads first is the
    // one on screen, even if the tab changed before it arrived.
    for (var j = 0; j < images.length; j++) {
        if (images[j].complete && images[j].naturalWidth > 0) {
            prefetchOthers();
        } else {
            images[j].addEventListener('load', prefetchOthers);
        }
    }
})();
