// Interpreting a stored endpoint.
//
// The preference holds the base only — up to and including the version segment, such as
// https://api.deepseek.com/v1. Both routes are derived from it here so the chat call and the model
// listing can never disagree about what the user typed, and so a pasted full URL still works.

const CHAT_SUFFIX = '/chat/completions';

/** The base with a chat suffix and trailing slashes removed. */
export function normalizeBase(baseUrl: string): string {
  let base = baseUrl.trim();
  if (base.endsWith(CHAT_SUFFIX)) {
    base = base.substring(0, base.length - CHAT_SUFFIX.length);
  }
  while (base.length > 0 && base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base;
}

export function chatUrl(baseUrl: string): string {
  return normalizeBase(baseUrl) + CHAT_SUFFIX;
}

export function modelsUrl(baseUrl: string): string {
  return normalizeBase(baseUrl) + '/models';
}

/** The host shown under the project name: scheme and path dropped, `api.` prefix removed. */
export function providerOf(baseUrl: string): string {
  const trimmed = baseUrl.trim();
  if (trimmed.length === 0) {
    return '';
  }
  let host = trimmed;
  const scheme = host.indexOf('://');
  if (scheme >= 0) {
    host = host.substring(scheme + 3);
  }
  const path = host.indexOf('/');
  if (path >= 0) {
    host = host.substring(0, path);
  }
  if (host.startsWith('api.')) {
    host = host.substring(4);
  }
  return host;
}
