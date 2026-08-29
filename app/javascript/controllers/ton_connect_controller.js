import { Controller } from "@hotwired/stimulus"
import { TonConnectUI } from "@tonconnect/ui"

const TON_MAINNET_CHAIN = "-239"
const DISCONNECT_TIMEOUT_MS = 3000

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
    this.tonConnectUi = new TonConnectUI({ manifestUrl: this.manifestUrlValue })
    this.unsubscribe = this.tonConnectUi.onStatusChange(
      (wallet) => this.handleStatusChange(wallet),
      () => this.showStatus(this.errorMessageValue),
    )
    this.unsubscribeModal = this.tonConnectUi.onModalStateChange((state) => {
      if (state.status !== "opened" && !this.finalizing) this.connectButtonTarget.disabled = false
    })
  }

  disconnect() {
    this.unsubscribe?.()
    this.unsubscribeModal?.()
  }

  async connectWallet() {
    this.userInitiated = false
    this.finalizing = false
    this.connectButtonTarget.disabled = true

    try {
      await this.tonConnectUi.connectionRestored

      // TonConnect persists by browser origin, not by Sure user/family. Never
      // reuse a restored session that may belong to a previous login on a
      // shared browser; make this click choose a wallet explicitly.
      if (this.tonConnectUi.connected) await this.disconnectWalletSession()

      // Set only after restoration and disconnection have settled. Otherwise a
      // late restored-status callback could race this click and submit the
      // previous browser user's wallet before the picker opens.
      this.userInitiated = true
      await this.tonConnectUi.openModal()
    } catch (_error) {
      this.showStatus(this.errorMessageValue)
      this.connectButtonTarget.disabled = false
      this.userInitiated = false
    }
  }

  async handleStatusChange(wallet) {
    if (!wallet || !this.userInitiated || this.finalizing) return

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

  showStatus(message) {
    this.statusTarget.textContent = message
    this.statusTarget.hidden = false
  }
}
