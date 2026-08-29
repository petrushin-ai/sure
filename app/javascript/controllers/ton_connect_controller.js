import { Controller } from "@hotwired/stimulus"
import { TonConnectUI } from "@tonconnect/ui"

const TON_MAINNET_CHAIN = "-239"
const DISCONNECT_TIMEOUT_MS = 3000
const MODAL_OPEN_TIMEOUT_MS = 8000

// Uses TonConnect only as an address picker. Sure never configures ton_proof,
// signing or transaction requests, and closes the dApp session before sending
// the public mainnet address to the ordinary read-only wallet flow.
export default class extends Controller {
  static targets = ["address", "chain", "form", "status", "connectButton"]
  static values = {
    manifestUrl: String,
    connectedMessage: String,
    errorMessage: String,
    mainnetOnlyMessage: String,
  }

  connect() {
    this.userInitiated = false
    this.finalizing = false
    this.modalOpened = false
    this.tonConnectUi = new TonConnectUI({
      manifestUrl: this.manifestUrlValue,
      // Sure only needs a public address. Restoring a persistent dApp session
      // adds no product value, can cross Sure logins on a shared browser and
      // may block forever while an unavailable bridge is contacted.
      restoreConnection: false,
    })
    this.unsubscribe = this.tonConnectUi.onStatusChange(
      (wallet) => this.handleStatusChange(wallet),
      () => this.showStatus(this.errorMessageValue),
    )
    this.unsubscribeModal = this.tonConnectUi.onModalStateChange((state) => {
      this.modalOpened = state.status === "opened"
      if (this.modalOpened) this.clearModalOpenTimeout()
      if (!this.modalOpened && !this.finalizing) this.connectButtonTarget.disabled = false
    })
  }

  disconnect() {
    this.clearModalOpenTimeout()
    this.unsubscribe?.()
    this.unsubscribeModal?.()
  }

  connectWallet() {
    this.userInitiated = true
    this.finalizing = false
    this.modalOpened = false
    this.connectButtonTarget.disabled = true
    this.clearModalOpenTimeout()

    // Keep this call in the synchronous click stack. Waiting for a restored
    // session first can deadlock the button and loses the mobile browser's user
    // activation before it opens Wallet in Telegram.
    try {
      this.modalOpenTimeout = setTimeout(() => this.handleModalOpenFailure(), MODAL_OPEN_TIMEOUT_MS)
      Promise.resolve(this.tonConnectUi.openModal()).catch(() => this.handleModalOpenFailure())
    } catch (_error) {
      this.handleModalOpenFailure()
    }
  }

  async handleStatusChange(wallet) {
    if (!wallet || !this.userInitiated || this.finalizing) return

    this.clearModalOpenTimeout()

    if (String(wallet.account.chain) !== TON_MAINNET_CHAIN) {
      this.finalizing = true
      this.showStatus(this.mainnetOnlyMessageValue)
      await this.disconnectWalletSession()
      this.finalizing = false
      this.userInitiated = false
      this.connectButtonTarget.disabled = false
      return
    }

    this.finalizing = true
    const address = wallet.account.address
    this.showStatus(this.connectedMessageValue)

    // The server-side connection is the public address. Keeping the encrypted
    // dApp session after that handoff would add capability with no product use.
    await this.disconnectWalletSession()

    this.addressTarget.value = address
    this.chainTarget.value = "ton"
    this.formTarget.requestSubmit()
  }

  async disconnectWalletSession() {
    try {
      await Promise.race([
        this.tonConnectUi.disconnect(),
        new Promise((resolve) => setTimeout(resolve, DISCONNECT_TIMEOUT_MS)),
      ])
    } catch (_error) {
      // The address handoff remains read-only even if a wallet bridge is
      // temporarily unreachable while the SDK clears its session.
    }
  }

  handleModalOpenFailure() {
    this.clearModalOpenTimeout()
    if (this.modalOpened || this.finalizing) return

    this.showStatus(this.errorMessageValue)
    this.connectButtonTarget.disabled = false
    this.userInitiated = false
  }

  clearModalOpenTimeout() {
    if (!this.modalOpenTimeout) return

    clearTimeout(this.modalOpenTimeout)
    this.modalOpenTimeout = null
  }

  showStatus(message) {
    this.statusTarget.textContent = message
    this.statusTarget.hidden = false
  }
}
