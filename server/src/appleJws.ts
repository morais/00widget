// Verification of the JWS payloads Apple signs: StoreKit 2 transactions the
// app forwards, and App Store Server Notifications V2 that Apple POSTs here.
// Both use the same envelope, so both use this module.
//
// Verified 2026-08-19 against
// https://developer.apple.com/documentation/appstoreserverapi/jwsdecodedheader
// https://developer.apple.com/documentation/appstoreservernotifications/responsebodyv2
//
// The envelope is a compact JWS whose header carries `x5c`: the leaf
// certificate that signed the payload, its intermediate, and Apple Root CA -
// G3. Verifying it means walking that chain to a root we already trust, rather
// than trusting whatever the header hands us — an unchecked x5c is a
// self-signed forgery waiting to happen, because an attacker can put their own
// chain there just as easily as Apple's.
//
// This is hand-rolled rather than pulled from a library for the same reason
// the router is: `app-store-server-library` is Node-shaped (node:crypto,
// Buffer, jsonwebtoken) and does not run on Workers. What it needs from us is
// a DER walk and two ECDSA verifications, which WebCrypto provides.

/// A single trusted root, supplied by the caller rather than compiled in, so
/// tests can mint their own chain. Production passes `APPLE_ROOT_CA_G3_DER`.
export interface AppleJwsVerifyOptions {
  trustedRootDer: Uint8Array;
  /// Defaults to now. Present so tests can evaluate a chain at a fixed instant.
  now?: Date;
}

/// Apple's own chain is three long. The cap is on the parsing and verification
/// an anonymous caller can make this Worker do, not on Apple.
const MAX_X5C_CHAIN_LENGTH = 4;

export class AppleJwsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AppleJwsError";
  }
}

/// Verifies `jws` and returns its payload. Throws `AppleJwsError` on anything
/// that fails to check out — the caller has no use for a partial result.
export async function verifyAppleJws(
  jws: string,
  options: AppleJwsVerifyOptions,
): Promise<Record<string, unknown>> {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new AppleJwsError("malformed JWS");
  const [headerPart, payloadPart, signaturePart] = parts;

  const header = parseJsonObject(decodeBase64Url(headerPart), "JWS header");
  if (header.alg !== "ES256") {
    throw new AppleJwsError(`unsupported JWS algorithm: ${String(header.alg)}`);
  }
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2 || x5c.some((entry) => typeof entry !== "string")) {
    throw new AppleJwsError("JWS header has no usable x5c chain");
  }
  // Apple sends three: leaf, WWDR intermediate, root. One spare, and no more —
  // every extra element is a certificate parse and an ECDSA verification that
  // an unauthenticated caller can ask for on the notification endpoint.
  if (x5c.length > MAX_X5C_CHAIN_LENGTH) {
    throw new AppleJwsError("x5c chain is too long");
  }

  const chain = (x5c as string[]).map((entry, index) => {
    try {
      return parseCertificate(decodeBase64(entry));
    } catch (err) {
      throw new AppleJwsError(
        `x5c[${index}] is not a parseable certificate: ${(err as Error).message}`,
      );
    }
  });

  const now = options.now ?? new Date();
  await verifyChain(chain, options.trustedRootDer, now);

  // The leaf signs the payload. JWS ECDSA signatures are fixed-width r||s
  // (RFC 7515), not the DER encoding X.509 uses, so this one needs no
  // conversion — unlike the certificate signatures inside `verifyChain`.
  //
  // `alg: ES256` fixes this key at P-256 regardless of what the rest of the
  // chain uses, and a leaf presenting any other curve is not signing an ES256
  // JWS whatever it claims.
  if (chain[0].curve !== "P-256") {
    throw new AppleJwsError("ES256 requires a P-256 leaf key");
  }
  const leafKey = await importEcdsaPublicKey(chain[0]);
  const signature = decodeBase64Url(signaturePart);
  const signedBytes = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    leafKey,
    signature,
    signedBytes,
  );
  if (!ok) throw new AppleJwsError("JWS signature does not verify");

  return parseJsonObject(decodeBase64Url(payloadPart), "JWS payload");
}

/// Reads a JWS payload without verifying anything. Only for logging a payload
/// that already failed verification, and named to make that obvious at the
/// call site.
export function decodeAppleJwsPayloadUnverified(jws: string): Record<string, unknown> | null {
  const parts = jws.split(".");
  if (parts.length !== 3) return null;
  try {
    return parseJsonObject(decodeBase64Url(parts[1]), "JWS payload");
  } catch {
    return null;
  }
}

async function verifyChain(
  chain: ParsedCertificate[],
  trustedRootDer: Uint8Array,
  now: Date,
): Promise<void> {
  const root = chain[chain.length - 1];
  // Byte equality against the pinned root, rather than "some certificate in
  // the chain has a matching subject". Comparing names or public keys alone
  // would accept a chain that merely claims Apple's identity.
  if (!bytesEqual(root.der, trustedRootDer)) {
    throw new AppleJwsError("x5c chain does not terminate at the trusted root");
  }

  for (const [index, certificate] of chain.entries()) {
    if (now < certificate.notBefore || now > certificate.notAfter) {
      throw new AppleJwsError(`x5c[${index}] is outside its validity period`);
    }
  }

  // Signature linkage alone does not make a chain. Without asking whether each
  // issuer is *allowed* to issue, any end-entity certificate under the pinned
  // root works as an intermediate — and Apple hands those to every Developer
  // Program member. An attacker signs a certificate for their own key with the
  // one they legitimately hold and presents
  //
  //   [ forged leaf, their real leaf, WWDR intermediate, Apple Root CA - G3 ]
  //
  // which terminates at the pinned root and verifies link by link. That forges
  // any transaction or notification payload, for any bundle id.
  //
  // The trust anchor is deliberately exempt: it is trusted because its bytes
  // were pinned by configuration, which is a stronger statement than anything
  // its own extensions could make (RFC 5280 §6.1 treats it the same way).
  // Everything between it and the leaf has to prove it may sign.
  for (let index = 1; index < chain.length - 1; index++) {
    const issuer = chain[index];
    if (!issuer.isCa) {
      throw new AppleJwsError(`x5c[${index}] is not a CA certificate`);
    }
    // pathLenConstraint caps how many intermediates may appear *below* this
    // one, which here is everything from index 1 up to but excluding it.
    if (issuer.pathLenConstraint !== undefined && issuer.pathLenConstraint < index - 1) {
      throw new AppleJwsError(`x5c[${index}] exceeds its pathLenConstraint`);
    }
    // keyUsage is optional; where it is asserted it is binding.
    if (issuer.keyCertSign === false) {
      throw new AppleJwsError(`x5c[${index}] does not assert keyCertSign`);
    }
  }
  // A CA presenting itself as the signer of a JWS is not the shape Apple issues
  // and not one this verifier should invent a meaning for.
  if (chain[0].isCa) {
    throw new AppleJwsError("x5c[0] is a CA certificate, not a leaf");
  }

  // Each certificate is signed by the next one along. The root signs itself and
  // is trusted by pinning, so it needs no verification here.
  //
  // Curve and hash come from the certificates themselves, never from a
  // constant. Apple's own chain is the reason: the leaf that signs the JWS is
  // P-256/ES256, but Apple Root CA - G3 and the WWDR G6 intermediate above it
  // are P-384 and sign with ecdsa-with-SHA384. Assuming P-256 throughout makes
  // every real notification fail to verify with "Named curve mismatch".
  for (let index = 0; index < chain.length - 1; index++) {
    const child = chain[index];
    const parent = chain[index + 1];
    const parentKey = await importEcdsaPublicKey(parent);
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: child.signatureHash },
      parentKey,
      derEcdsaSignatureToRaw(child.signature, parent.componentLength),
      child.tbsDer,
    );
    if (!ok) {
      throw new AppleJwsError(`x5c[${index}] is not signed by x5c[${index + 1}]`);
    }
  }
}

function importEcdsaPublicKey(certificate: ParsedCertificate): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "spki",
    // A fresh copy: importKey wants an ArrayBuffer, and the parsed views are
    // windows onto the certificate's own buffer.
    certificate.publicKeyDer.slice().buffer as ArrayBuffer,
    { name: "ECDSA", namedCurve: certificate.curve },
    false,
    ["verify"],
  );
}

// ---------------------------------------------------------------------------
// Minimal DER
//
// Only what a certificate needs: definite-length tags, no BER, no streaming.
// Anything else throws, which is the right answer for input that claims to be
// an X.509 certificate and is not.
// ---------------------------------------------------------------------------

interface DerElement {
  tag: number;
  /// The contents, excluding tag and length.
  content: Uint8Array;
  /// Tag, length, and contents — what a signature is computed over.
  full: Uint8Array;
}

function readDer(bytes: Uint8Array, offset: number): { element: DerElement; next: number } {
  if (offset + 2 > bytes.length) throw new Error("truncated DER element");
  const tag = bytes[offset];
  // Only single-byte tags appear in a certificate; a high-tag-number form here
  // means the input is not one.
  if ((tag & 0x1f) === 0x1f) throw new Error("unsupported multi-byte DER tag");

  let cursor = offset + 1;
  const first = bytes[cursor++];
  let length: number;
  if (first < 0x80) {
    length = first;
  } else {
    const lengthBytes = first & 0x7f;
    // 0x80 is the indefinite form, which DER forbids outright.
    if (lengthBytes === 0 || lengthBytes > 4) throw new Error("unsupported DER length");
    if (cursor + lengthBytes > bytes.length) throw new Error("truncated DER length");
    length = 0;
    for (let i = 0; i < lengthBytes; i++) length = length * 256 + bytes[cursor++];
  }
  const end = cursor + length;
  if (end > bytes.length) throw new Error("DER element runs past end of input");
  return {
    element: {
      tag,
      content: bytes.subarray(cursor, end),
      full: bytes.subarray(offset, end),
    },
    next: end,
  };
}

/// Every element directly inside a constructed one.
function readDerChildren(content: Uint8Array): DerElement[] {
  const children: DerElement[] = [];
  let offset = 0;
  while (offset < content.length) {
    const { element, next } = readDer(content, offset);
    children.push(element);
    offset = next;
  }
  return children;
}

const DER_SEQUENCE = 0x30;
const DER_BOOLEAN = 0x01;
const DER_INTEGER = 0x02;
const DER_BIT_STRING = 0x03;
const DER_OCTET_STRING = 0x04;
const DER_OID = 0x06;
const DER_UTC_TIME = 0x17;
const DER_GENERALIZED_TIME = 0x18;
const DER_CONTEXT_0 = 0xa0;
/// tbsCertificate's `[3] EXPLICIT Extensions OPTIONAL`.
const DER_CONTEXT_3 = 0xa3;

const OID_BASIC_CONSTRAINTS = "2.5.29.19";
const OID_KEY_USAGE = "2.5.29.15";

/// keyCertSign is bit 5 of the KeyUsage BIT STRING, counted from the most
/// significant bit of the first content byte.
const KEY_USAGE_KEY_CERT_SIGN = 0x04;

/// The curves WebCrypto names, and the byte width of one half of an ECDSA
/// signature on each. Anything outside this table is refused rather than
/// guessed at.
type EcCurve = "P-256" | "P-384" | "P-521";

const NAMED_CURVES: Record<string, { curve: EcCurve; componentLength: number }> = {
  "1.2.840.10045.3.1.7": { curve: "P-256", componentLength: 32 },
  "1.3.132.0.34": { curve: "P-384", componentLength: 48 },
  "1.3.132.0.35": { curve: "P-521", componentLength: 66 },
};

const SIGNATURE_HASHES: Record<string, string> = {
  "1.2.840.10045.4.3.2": "SHA-256", // ecdsa-with-SHA256
  "1.2.840.10045.4.3.3": "SHA-384", // ecdsa-with-SHA384
  "1.2.840.10045.4.3.4": "SHA-512", // ecdsa-with-SHA512
};

interface ParsedCertificate {
  der: Uint8Array;
  /// tbsCertificate as it appears on the wire — the exact bytes the issuer
  /// signed. Re-encoding rather than slicing would risk producing different
  /// bytes for the same certificate.
  tbsDer: Uint8Array;
  signature: Uint8Array;
  /// Hash this certificate's own signature was computed with, so the issuer
  /// above it is verified with the algorithm actually used.
  signatureHash: string;
  publicKeyDer: Uint8Array;
  curve: EcCurve;
  /// Half-width of a signature made by *this* certificate's key.
  componentLength: number;
  notBefore: Date;
  notAfter: Date;
  /// basicConstraints cA. Absent extension means false, per RFC 5280.
  isCa: boolean;
  /// basicConstraints pathLenConstraint, when the certificate states one.
  pathLenConstraint?: number;
  /// keyUsage keyCertSign, or undefined when the extension is absent — which
  /// RFC 5280 reads as "unconstrained", not as "denied".
  keyCertSign?: boolean;
}

function parseCertificate(der: Uint8Array): ParsedCertificate {
  const { element: certificate } = readDer(der, 0);
  if (certificate.tag !== DER_SEQUENCE) throw new Error("certificate is not a SEQUENCE");
  const [tbs, signatureAlgorithm, signatureValue] = readDerChildren(certificate.content);
  if (!tbs || !signatureAlgorithm || !signatureValue) {
    throw new Error("certificate has too few fields");
  }
  if (signatureValue.tag !== DER_BIT_STRING) throw new Error("signature is not a BIT STRING");
  // First content byte of a BIT STRING counts unused trailing bits. For a
  // signature it is always zero, and the signature is what follows.
  const signature = signatureValue.content.subarray(1);

  const signatureOid = readOid(readDerChildren(signatureAlgorithm.content)[0]);
  const signatureHash = SIGNATURE_HASHES[signatureOid];
  if (!signatureHash) {
    throw new Error(`unsupported certificate signature algorithm ${signatureOid}`);
  }

  const tbsChildren = readDerChildren(tbs.content);
  // version is [0] EXPLICIT and optional; everything after it shifts by one
  // when it is present, which for any modern certificate it is.
  let index = tbsChildren[0]?.tag === DER_CONTEXT_0 ? 1 : 0;
  index += 1; // serialNumber
  index += 1; // signature (AlgorithmIdentifier)
  index += 1; // issuer
  const validity = tbsChildren[index++];
  index += 1; // subject
  const subjectPublicKeyInfo = tbsChildren[index];
  if (!validity || !subjectPublicKeyInfo) throw new Error("tbsCertificate is truncated");

  const [notBefore, notAfter] = readDerChildren(validity.content);
  if (!notBefore || !notAfter) throw new Error("validity is malformed");

  // What follows subjectPublicKeyInfo is optional and sparse: issuerUniqueID
  // [1], subjectUniqueID [2], extensions [3]. Found by tag rather than by
  // position, because any of them may be missing.
  const extensions = parseExtensions(
    tbsChildren.slice(index + 1).find((child) => child.tag === DER_CONTEXT_3),
  );

  // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, ... },
  // where an EC AlgorithmIdentifier is SEQUENCE { id-ecPublicKey, namedCurve }.
  const spkiAlgorithm = readDerChildren(subjectPublicKeyInfo.content)[0];
  if (!spkiAlgorithm) throw new Error("subjectPublicKeyInfo is malformed");
  const curveOid = readOid(readDerChildren(spkiAlgorithm.content)[1]);
  const named = NAMED_CURVES[curveOid];
  if (!named) throw new Error(`unsupported public key curve ${curveOid}`);

  return {
    der,
    tbsDer: tbs.full,
    signature,
    signatureHash,
    publicKeyDer: subjectPublicKeyInfo.full,
    curve: named.curve,
    componentLength: named.componentLength,
    notBefore: parseDerTime(notBefore),
    notAfter: parseDerTime(notAfter),
    ...extensions,
  };
}

interface CertificateExtensions {
  isCa: boolean;
  pathLenConstraint?: number;
  keyCertSign?: boolean;
}

/// The two extensions that decide whether a certificate may issue another.
///
/// Everything else in the extension list is skipped, including unrecognised
/// critical extensions: this is not a general-purpose path validator, and the
/// chain it validates is one Apple issues and a pinned root anchors.
function parseExtensions(container: DerElement | undefined): CertificateExtensions {
  const result: CertificateExtensions = { isCa: false };
  if (!container) return result;

  // [3] EXPLICIT wraps a single SEQUENCE OF Extension.
  const [list] = readDerChildren(container.content);
  if (!list || list.tag !== DER_SEQUENCE) return result;

  for (const extension of readDerChildren(list.content)) {
    if (extension.tag !== DER_SEQUENCE) continue;
    const fields = readDerChildren(extension.content);
    const oidElement = fields[0];
    if (!oidElement || oidElement.tag !== DER_OID) continue;
    const oid = readOid(oidElement);
    if (oid !== OID_BASIC_CONSTRAINTS && oid !== OID_KEY_USAGE) continue;

    // `critical` is a DEFAULT FALSE BOOLEAN that may or may not be encoded, so
    // the OCTET STRING is found by tag rather than at a fixed offset.
    const value = fields.find((field) => field.tag === DER_OCTET_STRING);
    if (!value) continue;

    if (oid === OID_BASIC_CONSTRAINTS) {
      const [inner] = readDerChildren(value.content);
      if (!inner || inner.tag !== DER_SEQUENCE) continue;
      for (const field of readDerChildren(inner.content)) {
        // BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE,
        //                                 pathLenConstraint INTEGER OPTIONAL }
        // Both are optional, so each is read by its tag.
        if (field.tag === DER_BOOLEAN) {
          result.isCa = field.content.some((byte) => byte !== 0);
        } else if (field.tag === DER_INTEGER) {
          result.pathLenConstraint = readSmallInteger(field.content);
        }
      }
    } else {
      // extnValue is an OCTET STRING wrapping the extension's own DER, so the
      // BIT STRING is one level in — the same unwrap basicConstraints needs.
      const [inner] = readDerChildren(value.content);
      if (!inner || inner.tag !== DER_BIT_STRING) continue;
      // First content byte counts unused trailing bits; an empty bit string
      // asserts nothing at all.
      const bits = inner.content.subarray(1);
      result.keyCertSign = bits.length > 0 && (bits[0] & KEY_USAGE_KEY_CERT_SIGN) !== 0;
    }
  }
  return result;
}

/// A non-negative DER INTEGER small enough to be a pathLenConstraint. Anything
/// larger is treated as no constraint rather than silently truncated.
function readSmallInteger(content: Uint8Array): number | undefined {
  let start = 0;
  while (start < content.length - 1 && content[start] === 0) start++;
  const trimmed = content.subarray(start);
  if (trimmed.length === 0 || trimmed.length > 4 || (trimmed[0] & 0x80) !== 0) return undefined;
  let value = 0;
  for (const byte of trimmed) value = value * 256 + byte;
  return value;
}

/// An OBJECT IDENTIFIER as its dotted decimal form.
function readOid(element: DerElement | undefined): string {
  if (!element || element.tag !== DER_OID) throw new Error("expected an OBJECT IDENTIFIER");
  const bytes = element.content;
  if (bytes.length === 0) throw new Error("empty OBJECT IDENTIFIER");
  // The first byte packs two arcs: 40 * first + second.
  const parts = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let value = 0;
  for (const byte of bytes.subarray(1)) {
    value = value * 128 + (byte & 0x7f);
    if ((byte & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

function parseDerTime(element: DerElement): Date {
  const text = new TextDecoder().decode(element.content);
  let iso: string;
  if (element.tag === DER_UTC_TIME) {
    // YYMMDDHHMMSSZ. RFC 5280 pins the two-digit year: 50-99 is 19xx, 00-49 is
    // 20xx. Certificates outlive naive guesses at this.
    const match = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new Error("malformed UTCTime");
    const twoDigitYear = Number(match[1]);
    const year = twoDigitYear >= 50 ? 1900 + twoDigitYear : 2000 + twoDigitYear;
    iso = `${year}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}Z`;
  } else if (element.tag === DER_GENERALIZED_TIME) {
    const match = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new Error("malformed GeneralizedTime");
    iso = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}Z`;
  } else {
    throw new Error("unsupported time type");
  }
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) throw new Error("unparseable certificate time");
  return parsed;
}

/// X.509 wraps an ECDSA signature as `SEQUENCE { INTEGER r, INTEGER s }`;
/// WebCrypto wants the fixed-width `r || s` of RFC 7515. The INTEGERs are
/// signed, so they carry a leading zero when the high bit is set and are short
/// when the value has leading zero bytes — both have to be normalised to the
/// component width of the curve that produced them, which is 32 bytes for
/// P-256 and 48 for the P-384 Apple's CA certificates use.
function derEcdsaSignatureToRaw(der: Uint8Array, componentLength: number): Uint8Array {
  const { element } = readDer(der, 0);
  if (element.tag !== DER_SEQUENCE) throw new Error("ECDSA signature is not a SEQUENCE");
  const [r, s] = readDerChildren(element.content);
  if (!r || !s) throw new Error("ECDSA signature is missing a component");
  const raw = new Uint8Array(componentLength * 2);
  raw.set(toFixedWidth(r.content, componentLength), 0);
  raw.set(toFixedWidth(s.content, componentLength), componentLength);
  return raw;
}

function toFixedWidth(value: Uint8Array, width: number): Uint8Array {
  let start = 0;
  while (start < value.length - 1 && value[start] === 0) start++;
  const trimmed = value.subarray(start);
  if (trimmed.length > width) throw new Error("ECDSA signature component is too large");
  const out = new Uint8Array(width);
  out.set(trimmed, width - trimmed.length);
  return out;
}

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

export function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function decodeBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  return decodeBase64(padded + "=".repeat((4 - (padded.length % 4)) % 4));
}

function parseJsonObject(bytes: Uint8Array, what: string): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new AppleJwsError(`${what} is not JSON`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new AppleJwsError(`${what} is not a JSON object`);
  }
  return parsed as Record<string, unknown>;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
