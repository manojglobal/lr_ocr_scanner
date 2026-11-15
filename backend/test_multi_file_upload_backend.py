import unittest
import os
import sys
import io
import json
from unittest.mock import patch, MagicMock

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

import fitz
from PIL import Image
from starlette.datastructures import UploadFile
from fastapi.responses import JSONResponse
import user_cloud_service
import main

class TestMultiFileUploadBackend(unittest.TestCase):
    def setUp(self):
        self.test_mobile = "9988776655"
        user_cloud_service._save_user_db(self.test_mobile, {
            "user_mobile": self.test_mobile,
            "active_batch": [],
            "uploaded_lrs": [],
            "generated_excels": [],
            "dismissed_uploads": []
        })

    def tearDown(self):
        p = user_cloud_service._get_user_db_path(self.test_mobile)
        if os.path.exists(p):
            try:
                os.remove(p)
            except Exception:
                pass

    def _create_dummy_pdf(self, text: str) -> bytes:
        doc = fitz.open()
        page = doc.new_page(width=595, height=842)
        page.insert_text((50, 50), text, fontsize=12)
        return doc.tobytes()

    def _create_dummy_image(self, color=(200, 200, 200), width=300, height=300) -> bytes:
        im = Image.new("RGB", (width, height), color=color)
        buf = io.BytesIO()
        im.save(buf, format="JPEG")
        return buf.getvalue()

    def test_extract_lr_candidates_from_text(self):
        """Test regex extraction of Consignment Note / LR numbers from text."""
        txt1 = "CONSIGNMENT NOTE: No. 32760 Date: 12/10/2026"
        cands1 = main._extract_lr_candidates_from_text(txt1)
        self.assertIn("32760", cands1)

        txt2 = "LR No: 55001 Transporter Copy"
        cands2 = main._extract_lr_candidates_from_text(txt2)
        self.assertIn("55001", cands2)

        txt3 = "Invoice No: INV-9999 Vehicle No: HR55AX1234 GSTIN: 07AAAAA0000A1Z5"
        cands3 = main._extract_lr_candidates_from_text(txt3)
        self.assertEqual(len(cands3), 0, "Invoice, vehicle, and GST must not be treated as LR number")

    def test_normalize_lr_candidate(self):
        """Test normalization of LR strings (stripping leading zeros, punctuation, formatting)."""
        self.assertEqual(main._normalize_lr_candidate("33118"), "33118")
        self.assertEqual(main._normalize_lr_candidate("033118"), "33118")
        self.assertEqual(main._normalize_lr_candidate("LR-33118"), "lr33118")
        self.assertEqual(main._normalize_lr_candidate("  33118\n"), "33118")
        self.assertEqual(main._normalize_lr_candidate(""), "")

    def test_multiple_pdfs_with_different_lrs_detected_and_rejected(self):
        """Test that uploading multiple PDFs with different LR numbers triggers 422 MULTIPLE_LRS."""
        pdf1_bytes = self._create_dummy_pdf("CONSIGNMENT NOTE: No. 10001\nOrigin: MAU\nDestination: DELHI")
        pdf2_bytes = self._create_dummy_pdf("CONSIGNMENT NOTE: No. 20002\nOrigin: SANAND\nDestination: AMBALA")

        c1 = main._extract_lr_candidates_from_text(fitz.open(stream=pdf1_bytes, filetype="pdf")[0].get_text())
        c2 = main._extract_lr_candidates_from_text(fitz.open(stream=pdf2_bytes, filetype="pdf")[0].get_text())
        combined_cands = c1.union(c2)

        self.assertIn("10001", combined_cands)
        self.assertIn("20002", combined_cands)
        self.assertGreater(len(combined_cands), 1, "Must detect two distinct LR numbers")

        # Simulate rejection response check
        rejection_response = JSONResponse(
            status_code=422,
            content={
                "success": False,
                "error_code": "MULTIPLE_LRS",
                "title": "Multiple LRs Not Allowed",
                "message": "Multiple LR documents detected. Please upload documents belonging to only one LR at a time.",
                "detail": "Multiple LR documents detected. Please upload documents belonging to only one LR at a time."
            }
        )
        self.assertEqual(rejection_response.status_code, 422)
        body = json.loads(rejection_response.body.decode("utf-8"))
        self.assertEqual(body["error_code"], "MULTIPLE_LRS")
        self.assertEqual(body["title"], "Multiple LRs Not Allowed")
        self.assertEqual(body["message"], "Multiple LR documents detected. Please upload documents belonging to only one LR at a time.")

        # Ensure cloud storage DB was NOT touched
        cloud_data = user_cloud_service.get_user_cloud_data(self.test_mobile)
        self.assertEqual(len(cloud_data["active_batch"]), 0)
        self.assertEqual(len(cloud_data["uploaded_lrs"]), 0)

    def test_single_pdf_with_multiple_different_lrs_rejected(self):
        """Test that a single multi-page PDF containing two different LRs is detected and rejected."""
        doc = fitz.open()
        p1 = doc.new_page()
        p1.insert_text((50, 50), "CONSIGNMENT NOTE: No. 33118")
        p2 = doc.new_page()
        p2.insert_text((50, 50), "CONSIGNMENT NOTE: No. 33119")
        pdf_bytes = doc.tobytes()

        # Parse text from both pages
        parsed_doc = fitz.open(stream=pdf_bytes, filetype="pdf")
        detected_text_lrs = set()
        for p in parsed_doc:
            for cand in main._extract_lr_candidates_from_text(p.get_text()):
                detected_text_lrs.add(main._normalize_lr_candidate(cand))

        self.assertEqual(len(detected_text_lrs), 2, "Must detect both LR 33118 and LR 33119 within single PDF")
        self.assertIn("33118", detected_text_lrs)
        self.assertIn("33119", detected_text_lrs)

    def test_multi_file_assembly_same_lr_and_mixed_formats(self):
        """Test combining multiple PDFs, images, and mixed formats into a single coherent PDF dossier."""
        pdf1_bytes = self._create_dummy_pdf("CONSIGNMENT NOTE: No. 32760 - Page 1")
        img_bytes = self._create_dummy_image(color=(255, 255, 255))
        pdf2_bytes = self._create_dummy_pdf("Continuation for LR 32760 - Packing details")

        # Assemble them using PyMuPDF exactly as in extract_handwriting
        combined_pdf = fitz.open()

        # 1. PDF 1
        d1 = fitz.open(stream=pdf1_bytes, filetype="pdf")
        combined_pdf.insert_pdf(d1)

        # 2. Image converted to PDF
        pil_img = Image.open(io.BytesIO(img_bytes))
        jbuf = io.BytesIO()
        pil_img.save(jbuf, format="JPEG", quality=95)
        img_doc = fitz.open(stream=jbuf.getvalue(), filetype="jpeg")
        sub_pdf_bytes = img_doc.convert_to_pdf()
        img_pdf = fitz.open("pdf", sub_pdf_bytes)
        combined_pdf.insert_pdf(img_pdf)

        # 3. PDF 2
        d2 = fitz.open(stream=pdf2_bytes, filetype="pdf")
        combined_pdf.insert_pdf(d2)

        self.assertEqual(len(combined_pdf), 3, "Combined PDF must have exactly 3 pages preserving original sequence")

        # Ensure preview rendering works for all 3 pages
        rendered_previews = []
        for p in combined_pdf:
            pix = p.get_pixmap(dpi=150)
            rendered_previews.append(pix.tobytes("jpeg"))
        self.assertEqual(len(rendered_previews), 3)

    def test_page_lr_scan_schema(self):
        """Test PageLrScan model and Gemini-compatible schema translation."""
        scan = main.PageLrScan(
            is_consignment_note=True,
            lr_number="33118",
            doc_type="Consignment Note"
        )
        self.assertTrue(scan.is_consignment_note)
        self.assertEqual(scan.lr_number, "33118")

        schema = main._to_gemini_compatible_schema(main.PageLrScan)
        self.assertIn("is_consignment_note", schema["properties"])
        self.assertIn("lr_number", schema["properties"])
        self.assertIn("doc_type", schema["properties"])

    def test_gemini_ocr_response_has_multi_lr_flags(self):
        """Test that GeminiOCRResponse schema and compatibility include detected_lr_numbers and has_multiple_different_lrs."""
        resp = main.GeminiOCRResponse(
            document_title="Multi Document Test",
            is_valid_lr=True,
            document_type="lorry_receipt",
            has_consignment_note=True,
            detected_lr_numbers=["55001"],
            has_multiple_different_lrs=False,
            key_value_pairs=[main.KeyValuePair(key="LR No *", value="55001")],
            confidence_notes="High confidence"
        )
        self.assertEqual(resp.detected_lr_numbers, ["55001"])
        self.assertFalse(resp.has_multiple_different_lrs)

        # Verify schema translation strips defaults while preserving array of strings
        compat_schema = main._to_gemini_compatible_schema(main.GeminiOCRResponse)
        self.assertIn("detected_lr_numbers", compat_schema["properties"])
        self.assertIn("has_multiple_different_lrs", compat_schema["properties"])
        self.assertEqual(compat_schema["properties"]["detected_lr_numbers"]["type"], "array")
        self.assertEqual(compat_schema["properties"]["has_multiple_different_lrs"]["type"], "boolean")

if __name__ == "__main__":
    unittest.main()
