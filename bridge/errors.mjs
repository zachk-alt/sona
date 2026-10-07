export class BridgeError extends Error {
  constructor(code) { super(code); this.code = code; }
}
export const fail = (code) => { throw new BridgeError(code); };
export const reasonFor = (error) => error instanceof BridgeError ? error.code : 'bridge_failed';
