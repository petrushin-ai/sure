// TonConnect's browser bundle imports the Node module names through optional
// compatibility paths. Browsers use `globalThis.crypto`, `atob` and `btoa`
// instead, so no Node implementation should be shipped to the client.
export default {}
