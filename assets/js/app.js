// PERP WALK — Phoenix LiveView socket setup

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let Hooks = {
  FlashAutoClear: {
    mounted() {
      const ms = parseInt(this.el.dataset.dismissAfter || "4000", 10)
      this.timer = setTimeout(() => {
        this.el.style.transition = "opacity 0.5s ease-in"
        this.el.style.opacity = "0"
        setTimeout(() => this.el.click(), 500)
      }, ms)
    },
    destroyed() {
      if (this.timer) clearTimeout(this.timer)
    }
  },
  CopyOnClick: {
    mounted() {
      this.el.addEventListener("click", () => {
        const text = this.el.dataset.copyText
        if (text && navigator.clipboard) navigator.clipboard.writeText(text)
      })
    }
  },
  ModalFocusTrap: {
    // Focus management for `.bp-modal-overlay > [role=dialog]`:
    // focuses the first focusable element on mount, traps Tab/
    // Shift+Tab within the dialog, fires the dataset-named LiveView
    // event on Escape. Restores focus to the previously-focused
    // element on destroy.
    mounted() {
      this.previouslyFocused = document.activeElement
      this.dialog = this.el.querySelector('[role="dialog"]') || this.el
      this.dialog.setAttribute("tabindex", "-1")

      this.handleKeydown = (e) => {
        if (e.key === "Escape") {
          const ev = this.el.dataset.closeEvent
          if (ev) this.pushEvent(ev)
        } else if (e.key === "Tab") {
          const focusables = this.dialog.querySelectorAll(
            'a[href], button:not([disabled]), textarea, input, select, [tabindex]:not([tabindex="-1"])'
          )
          if (focusables.length === 0) {
            e.preventDefault()
            this.dialog.focus()
            return
          }
          const first = focusables[0]
          const last = focusables[focusables.length - 1]
          if (e.shiftKey && document.activeElement === first) {
            e.preventDefault()
            last.focus()
          } else if (!e.shiftKey && document.activeElement === last) {
            e.preventDefault()
            first.focus()
          }
        }
      }

      this.el.addEventListener("keydown", this.handleKeydown)

      const focusables = this.dialog.querySelectorAll(
        'a[href], button:not([disabled]), textarea, input, select, [tabindex]:not([tabindex="-1"])'
      )
      ;(focusables[0] || this.dialog).focus()
    },
    destroyed() {
      if (this.previouslyFocused && this.previouslyFocused.focus) {
        this.previouslyFocused.focus()
      }
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// heartbeatIntervalMs default is 30000. Doubling to 60000 halves the
// per-user circuit wake-up cadence over Tor — the dominant cost is
// scheduling work on a multiplexed circuit, not the heartbeat payload
// itself. Server-side WS timeout is 120_000 to tolerate one missed
// heartbeat with network jitter without dropping the connection.
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
  heartbeatIntervalMs: 60000
})

liveSocket.connect()

window.liveSocket = liveSocket
