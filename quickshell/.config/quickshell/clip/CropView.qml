// CropView.qml — the frame with the crop over it, like the iPhone's Crop tool: everything outside
// the rectangle dimmed, a rule-of-thirds grid inside, corners and edges to drag, the inside to
// move it, the picture turned and mirrored as chosen. Coordinates are pixels of the rotated frame
// (Store.rotW x Store.rotH); `s` maps them to the screen.
import QtQuick

Item {
    id: view

    readonly property real pad: 24
    readonly property real s: Store.rotW > 0 && Store.rotH > 0 ? Math.min((width - pad * 2) / Store.rotW, (height - pad * 2) / Store.rotH) : 1
    readonly property real cw: Store.rotW * s
    readonly property real ch: Store.rotH * s
    readonly property real grab: 18             // how close to a corner or an edge counts as grabbing it
    readonly property bool locked: Store.aspectRatio > 0

    // the picture: the frame clip.py extracted (already in the file's own orientation), turned by
    // Store.rotate inside, mirrored outside, so the order matches ffmpeg's transpose-then-flip
    Rectangle {
        id: canvas
        width: view.cw
        height: view.ch
        anchors.centerIn: parent
        color: Ui.crust
        clip: true
        transform: Scale { origin.x: canvas.width / 2; origin.y: canvas.height / 2; xScale: Store.flipH ? -1 : 1; yScale: Store.flipV ? -1 : 1 }
        Image {
            id: pic
            width: Store.srcW * view.s
            height: Store.srcH * view.s
            anchors.centerIn: parent
            source: Store.frameUrl
            cache: false
            asynchronous: true
            smooth: true
            mipmap: true
            fillMode: Image.Stretch
            transform: Rotation { origin.x: pic.width / 2; origin.y: pic.height / 2; angle: Store.rotate }
        }
        Text {
            anchors.centerIn: parent
            visible: Store.frameUrl === "" && Store.ready
            text: Store.frameBusy ? "reading the frame…" : "no frame"
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
        }
    }

    // the crop in screen coordinates
    readonly property real cx: canvas.x + Store.cropX * s
    readonly property real cy: canvas.y + Store.cropY * s
    readonly property real cwid: Store.cropW * s
    readonly property real chei: Store.cropH * s

    // the veil outside the crop (four rectangles, so the inside stays as it is)
    Rectangle { x: canvas.x; y: canvas.y; width: canvas.width; height: Math.max(0, view.cy - canvas.y); color: "black"; opacity: 0.55 }
    Rectangle { x: canvas.x; y: view.cy + view.chei; width: canvas.width; height: Math.max(0, canvas.y + canvas.height - y); color: "black"; opacity: 0.55 }
    Rectangle { x: canvas.x; y: view.cy; width: Math.max(0, view.cx - canvas.x); height: view.chei; color: "black"; opacity: 0.55 }
    Rectangle { x: view.cx + view.cwid; y: view.cy; width: Math.max(0, canvas.x + canvas.width - x); height: view.chei; color: "black"; opacity: 0.55 }

    // the rectangle, its grid and its handles
    Item {
        id: box
        x: view.cx; y: view.cy; width: view.cwid; height: view.chei
        Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.9) }
        Repeater {
            model: 2
            Rectangle { required property int index; x: parent.width * (index + 1) / 3; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, area.pressed ? 0.6 : 0.3) }
        }
        Repeater {
            model: 2
            Rectangle { required property int index; y: parent.height * (index + 1) / 3; height: 1; width: parent.width; color: Qt.rgba(1, 1, 1, area.pressed ? 0.6 : 0.3) }
        }
        // corners: thick L marks, like the iPhone's
        Repeater {
            model: [[0, 0], [1, 0], [0, 1], [1, 1]]
            Item {
                required property var modelData
                readonly property bool atRight: modelData[0] === 1
                readonly property bool atBottom: modelData[1] === 1
                x: atRight ? box.width - 22 : -2
                y: atBottom ? box.height - 22 : -2
                width: 24; height: 24
                Rectangle { x: 0; y: atBottom ? 20 : 0; width: 24; height: 4; radius: 1; color: "white" }
                Rectangle { x: atRight ? 20 : 0; y: 0; width: 4; height: 24; radius: 1; color: "white" }
            }
        }
        // edge marks
        Rectangle { x: parent.width / 2 - 16; y: -2; width: 32; height: 4; radius: 1; color: "white"; opacity: 0.9 }
        Rectangle { x: parent.width / 2 - 16; y: parent.height - 2; width: 32; height: 4; radius: 1; color: "white"; opacity: 0.9 }
        Rectangle { x: -2; y: parent.height / 2 - 16; width: 4; height: 32; radius: 1; color: "white"; opacity: 0.9 }
        Rectangle { x: parent.width - 2; y: parent.height / 2 - 16; width: 4; height: 32; radius: 1; color: "white"; opacity: 0.9 }
        // the size, while dragging
        Rectangle {
            visible: area.pressed
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.top
            anchors.bottomMargin: 6
            width: sizeText.implicitWidth + 12; height: 20; radius: 5
            color: Ui.crust; opacity: 0.9
            Text { id: sizeText; anchors.centerIn: parent; text: Store.even(Store.cropW) + " × " + Store.even(Store.cropH); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: Store.ready
        // what the press took hold of: "move", or a combination of n/s/e/w
        property string mode: ""
        property real startX: 0
        property real startY: 0
        property var start: ({})      // the crop at the press
        cursorShape: {
            const m = pressed ? mode : hit(mouseX, mouseY)
            if (m === "move") return pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            if (m === "n" || m === "s") return Qt.SizeVerCursor
            if (m === "e" || m === "w") return Qt.SizeHorCursor
            if (m === "nw" || m === "se") return Qt.SizeFDiagCursor
            if (m === "ne" || m === "sw") return Qt.SizeBDiagCursor
            return Qt.ArrowCursor
        }
        function hit(mx, my) {
            const g = view.grab
            const nearW = Math.abs(mx - view.cx) <= g, nearE = Math.abs(mx - (view.cx + view.cwid)) <= g
            const nearN = Math.abs(my - view.cy) <= g, nearS = Math.abs(my - (view.cy + view.chei)) <= g
            const insideX = mx >= view.cx - g && mx <= view.cx + view.cwid + g
            const insideY = my >= view.cy - g && my <= view.cy + view.chei + g
            if (!insideX || !insideY) return ""
            let m = ""
            if (nearN) m += "n"; else if (nearS) m += "s"
            if (nearW) m += "w"; else if (nearE) m += "e"
            if (m) return m
            return mx > view.cx && mx < view.cx + view.cwid && my > view.cy && my < view.cy + view.chei ? "move" : ""
        }
        onPressed: mouse => {
            mode = hit(mouse.x, mouse.y)
            if (!mode) { mouse.accepted = false; return }
            startX = mouse.x; startY = mouse.y
            start = { x: Store.cropX, y: Store.cropY, w: Store.cropW, h: Store.cropH }
        }
        onReleased: mode = ""
        onPositionChanged: mouse => {
            if (!pressed || !mode) return
            const dx = (mouse.x - startX) / view.s, dy = (mouse.y - startY) / view.s
            if (mode === "move") { Store.setCropRect(start.x + dx, start.y + dy, start.w, start.h); return }
            view.resize(mode, start, dx, dy)
        }
    }

    // a corner or edge dragged by (dx, dy) source pixels from `st`; the opposite side stays put,
    // the ratio holds when an aspect is chosen, nothing leaves the frame
    function resize(mode, st, dx, dy) {
        const W = Store.rotW, H = Store.rotH, min = 16, r = Store.aspectRatio
        let x = st.x, y = st.y, w = st.w, h = st.h
        const n = mode.includes("n"), so = mode.includes("s"), e = mode.includes("e"), we = mode.includes("w")
        // the anchor: the side that does not move
        const ax = we ? st.x + st.w : st.x
        const ay = n ? st.y + st.h : st.y
        if (e) w = st.w + dx
        if (we) w = st.w - dx
        if (so) h = st.h + dy
        if (n) h = st.h - dy
        w = Math.max(min, w); h = Math.max(min, h)
        if (r > 0) {
            if ((e || we) && !(n || so)) h = w / r             // an edge: the other dimension follows
            else if ((n || so) && !(e || we)) w = h * r
            else if (w / h > r) h = w / r; else w = h * r       // a corner: the larger wish wins
        }
        // room on each side of the anchor
        const roomW = (we ? ax : W - ax), roomH = (n ? ay : H - ay)
        if (r > 0 && !(n || so)) {
            // an edge with a ratio grows around the middle of the other axis
            const cy = st.y + st.h / 2
            const maxH = Math.min(cy, H - cy) * 2
            if (h > maxH) { h = maxH; w = h * r }
            if (w > roomW) { w = roomW; h = w / r }
            y = cy - h / 2
        } else if (r > 0 && !(e || we)) {
            const cx = st.x + st.w / 2
            const maxW = Math.min(cx, W - cx) * 2
            if (w > maxW) { w = maxW; h = w / r }
            if (h > roomH) { h = roomH; w = h * r }
            x = cx - w / 2
        } else {
            if (w > roomW) { w = roomW; if (r > 0) h = w / r }
            if (h > roomH) { h = roomH; if (r > 0) w = h * r }
        }
        if (we) x = ax - w
        if (e) x = ax
        if (n) y = ay - h
        if (so) y = ay
        if (!(n || so) && !(r > 0)) y = st.y
        if (!(e || we) && !(r > 0)) x = st.x
        Store.setCropRect(x, y, w, h)
    }
}
