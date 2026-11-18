/**
 * Save a string to the user's machine as a file.
 *
 * Latin-1 rather than UTF-8: a PDF's bytes are not text, and handing the browser a
 * UTF-8 encoded string would corrupt every byte above 0x7F and produce a file that
 * opens to a blank page. The typings are one byte per character, which is what a
 * PDF wants.
 */
export function downloadTextFile(filename: string, body: string, mime = 'application/pdf'): void {
  const blob = new Blob([body], { type: `${mime};charset=iso-8859-1` });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Revoking immediately can cancel the download in some browsers; the delay is
  // long enough that the click has been handled and short enough not to leak.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
