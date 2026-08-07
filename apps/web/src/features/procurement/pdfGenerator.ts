import { jsPDF } from "jspdf";

// Builds the PO document as a Blob, laid out to match the reference
// "Purchase Order and Approval Form" (request no / PO no / SAP project no
// header, bordered purchase list, summary lines, three-column signature
// block). No external table library -- cells are drawn by hand with
// jsPDF's own rect/line/splitTextToSize so this has no new dependency.

interface LineItem {
  material_service: string;
  cost_code: string | null;
  place_of_use: string | null;
  quantity: number;
  unit_price: number | null;
  total: number | null;
  currency: string;
}

interface Approval {
  stage_name: string;
  approver_role: string | null;
  approver_name: string;
  sequence_order: number;
}

interface PoPdfData {
  po_number: string;
  initial_po_number: string | null;
  company: string; // supplier / vendor name
  po_total: number;
  currency: string;
  po_date: string;
  mr_number: string;
  mr_title: string;
  requester_name: string;
  purchaser_name: string | null;
  delivery_date: string | null;
  organization_name: string | null;
  project_sap_no: string | null;
  payment_conditions: string | null;
  terms_of_delivery: string | null;
  primary_cost_code: string | null;
  line_items: LineItem[];
  approvals: Approval[];
}

const PAGE_WIDTH = 595.28; // A4 pt
const MARGIN_X = 40;
const CONTENT_WIDTH = PAGE_WIDTH - MARGIN_X * 2;
const PAGE_BOTTOM = 780;

const fmtAmount = (n: number | null | undefined) =>
  n == null ? "-" : n.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 3 });

const fmtDate = (d: string | null | undefined) => {
  if (!d) return "-";
  const parsed = new Date(d);
  return Number.isNaN(parsed.getTime()) ? d : parsed.toLocaleDateString();
};

export function buildPoPdf(data: PoPdfData): Blob {
  const doc = new jsPDF({ unit: "pt", format: "a4" });
  let y = 40;

  const ensureRoom = (needed: number) => {
    if (y + needed > PAGE_BOTTOM) {
      doc.addPage();
      y = 40;
    }
  };

  // ---- Top header: Request No / PO No / Project SAP No ------------------
  doc.setFontSize(9);
  doc.setFont("helvetica", "normal");
  doc.text(`REQUEST NO : ${data.mr_number}`, MARGIN_X, y);
  y += 13;
  doc.setFont("helvetica", "bold");
  doc.text(`PURCHASE ORDER NO : ${data.po_number}`, MARGIN_X, y);
  y += 13;
  doc.setFont("helvetica", "normal");
  doc.text(`PROJECT SAP NO ${data.project_sap_no ?? "-"}`, MARGIN_X, y);
  y += 20;

  // ---- Title block --------------------------------------------------------
  doc.setFontSize(13);
  doc.setFont("helvetica", "bold");
  doc.text("PURCHASE ORDER AND APPROVAL FORM", PAGE_WIDTH / 2, y, { align: "center" });
  y += 16;
  doc.setFontSize(10);
  doc.text(data.mr_title || "-", PAGE_WIDTH / 2, y, { align: "center" });
  y += 16;
  doc.setFontSize(9);
  doc.setFont("helvetica", "normal");
  doc.text(data.organization_name ?? "-", MARGIN_X, y);
  doc.text(`Date of Request : ${fmtDate(data.po_date)}`, PAGE_WIDTH - MARGIN_X, y, { align: "right" });
  y += 18;

  doc.setFont("helvetica", "bold");
  doc.text("SUPPLIER :", MARGIN_X, y);
  doc.setFont("helvetica", "normal");
  doc.text(data.company || "-", MARGIN_X + 60, y);
  y += 18;

  // ---- Purchase list table ------------------------------------------------
  doc.setFont("helvetica", "bold");
  doc.setFontSize(9);
  doc.text("PURCHASE LIST", MARGIN_X, y);
  y += 8;

  // Column layout: Cost Code / Material-Service / Place of use / Unit Price / Qty / Currency / Amount
  //
  // FIX: this column previously was labeled "Unit" but was filled with
  // li.currency (e.g. "UGX") -- LineItem has no unit-of-measure field at
  // all, so the old label was actively misleading on the printed PO.
  // Relabeled to "Currency" to match what's actually rendered, rather
  // than inventing unit data we don't have.
  const cols = [
    { key: "cost_code", label: "Cost Code Description", width: 100 },
    { key: "material_service", label: "Material/Services", width: 110 },
    { key: "place_of_use", label: "Place of use", width: 65 },
    { key: "unit_price", label: "Unit Price", width: 80 },
    { key: "quantity", label: "Qty", width: 35 },
    { key: "currency", label: "Currency", width: 35 },
    { key: "amount", label: "Amount", width: 90 },
  ] as const;
  const colX: number[] = [];
  let cursorX = MARGIN_X;
  cols.forEach((c) => {
    colX.push(cursorX);
    cursorX += c.width;
  });
  const tableRight = MARGIN_X + cols.reduce((s, c) => s + c.width, 0);

  const drawTableHeader = () => {
    doc.setFillColor(235, 235, 235);
    doc.rect(MARGIN_X, y, tableRight - MARGIN_X, 22, "F");
    doc.setDrawColor(0);
    doc.rect(MARGIN_X, y, tableRight - MARGIN_X, 22);
    doc.setFont("helvetica", "bold");
    doc.setFontSize(7.5);
    cols.forEach((c, i) => {
      const lines = doc.splitTextToSize(c.label, c.width - 6);
      doc.text(lines, colX[i] + 3, y + 9);
      if (i > 0) doc.line(colX[i], y, colX[i], y + 22);
    });
    y += 22;
  };

  ensureRoom(22);
  drawTableHeader();

  doc.setFont("helvetica", "normal");
  doc.setFontSize(8);

  data.line_items.forEach((li) => {
    const descLines = doc.splitTextToSize(li.cost_code ?? "-", cols[0].width - 6);
    const matLines = doc.splitTextToSize(li.material_service ?? "-", cols[1].width - 6);
    const placeLines = doc.splitTextToSize(li.place_of_use ?? "-", cols[2].width - 6);
    const rowLines = Math.max(descLines.length, matLines.length, placeLines.length, 1);
    const rowHeight = Math.max(18, rowLines * 10 + 6);

    ensureRoom(rowHeight);
    if (y === 40) drawTableHeader(); // re-drew header after a page break

    doc.rect(MARGIN_X, y, tableRight - MARGIN_X, rowHeight);
    cols.forEach((_, i) => {
      if (i > 0) doc.line(colX[i], y, colX[i], y + rowHeight);
    });

    doc.text(descLines, colX[0] + 3, y + 10);
    doc.text(matLines, colX[1] + 3, y + 10);
    doc.text(placeLines, colX[2] + 3, y + 10);
    doc.text(fmtAmount(li.unit_price), colX[3] + cols[3].width - 3, y + 10, { align: "right" });
    doc.text(String(li.quantity ?? "-"), colX[4] + cols[4].width - 3, y + 10, { align: "right" });
    doc.text(li.currency || "-", colX[5] + 3, y + 10);
    doc.text(fmtAmount(li.total), colX[6] + cols[6].width - 3, y + 10, { align: "right" });

    y += rowHeight;
  });

  if (data.line_items.length === 0) {
    ensureRoom(20);
    doc.rect(MARGIN_X, y, tableRight - MARGIN_X, 20);
    doc.text("No itemized line items recorded for this request.", MARGIN_X + 4, y + 13);
    y += 20;
  }

  y += 16;

  // ---- Summary lines --------------------------------------------------------
  const summaryField = (label: string, value: string, bold = false) => {
    ensureRoom(14);
    doc.setFont("helvetica", "normal");
    doc.setFontSize(9);
    doc.text(label, MARGIN_X, y);
    doc.setFont("helvetica", bold ? "bold" : "normal");
    doc.text(value, MARGIN_X + 150, y);
    y += 14;
  };

  summaryField("Amount of offer (w/o VAT)", `${fmtAmount(data.po_total)} ${data.currency}`, true);
  summaryField("Delivery Date", fmtDate(data.delivery_date));
  summaryField("Payment Conditions", data.payment_conditions ?? "-");
  summaryField("Terms of Delivery", data.terms_of_delivery ?? "-");

  y += 14;

  // ---- Signature block: Requester / Purchaser / Approval by ----------------
  ensureRoom(60);
  const sigColWidth = CONTENT_WIDTH / 3;
  const sigColX = [MARGIN_X, MARGIN_X + sigColWidth, MARGIN_X + sigColWidth * 2];

  doc.setFont("helvetica", "bold");
  doc.setFontSize(9);
  doc.text("Requester", sigColX[0], y);
  doc.text("Purchaser", sigColX[1], y);
  doc.text("Approval by", sigColX[2], y);
  y += 4;
  doc.line(MARGIN_X, y, tableRight, y);
  y += 12;

  doc.setFont("helvetica", "normal");
  doc.setFontSize(8.5);
  doc.text(data.requester_name || "-", sigColX[0], y);
  doc.text(data.purchaser_name || "-", sigColX[1], y);

  const approvalLines =
    data.approvals.length > 0
      ? data.approvals.map(
          (a) => `${data.primary_cost_code ?? ""} ${a.stage_name} ${a.approver_name}`.trim()
        )
      : ["-"];

  // FIX: approvalY previously tracked separately from the module-level
  // `y` used by ensureRoom(). If the approval list was long enough to
  // trigger a page break mid-loop, ensureRoom() would reset `y` to 40
  // (top of the new page) but `approvalY` kept climbing from its old,
  // now-stale value -- so remaining lines were drawn at leftover
  // coordinates from the previous page (off-canvas or overlapping other
  // content). Now `y` and `approvalY` are kept in sync on every
  // iteration: `y` is set to the running position before ensureRoom()
  // checks/resets it, then `approvalY` is read back from `y` so both
  // reflect the same, possibly-just-reset, page position.
  let approvalY = y;
  approvalLines.forEach((line) => {
    y = approvalY;
    ensureRoom(12);
    approvalY = y;
    const wrapped = doc.splitTextToSize(line, sigColWidth - 8);
    doc.text(wrapped, sigColX[2], approvalY);
    approvalY += wrapped.length * 11;
  });

  y = Math.max(y, approvalY) + 10;

  // ---- Footer ---------------------------------------------------------------
  ensureRoom(16);
  // FIX: `PAGE_BOTTOM + 10 > y` was true in virtually every real case
  // (790 > y almost always holds), so this ternary always resolved to
  // `y` and the `PAGE_BOTTOM` branch was dead code -- the footer just
  // trailed whatever content preceded it instead of being pinned to the
  // bottom of the page. ensureRoom(16) above already guarantees
  // y <= PAGE_BOTTOM at this point, so pinning to PAGE_BOTTOM (with `y`
  // only as a defensive fallback) gives the intended fixed-position
  // footer.
  const footerY = Math.max(y, PAGE_BOTTOM);
  doc.setFontSize(7.5);
  doc.setTextColor(120);
  doc.text(`Generated ${new Date().toLocaleString()}`, MARGIN_X, footerY);
  doc.setTextColor(0);

  return doc.output("blob");
}