import unittest
import os
import sys
import asyncio

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, CURRENT_DIR)

from fastapi import HTTPException

from main import (
    _load_manifest_data,
    _load_manifest_parties,
    _load_counters_data,
    validate_department_exact,
    validate_counter_exact,
    auto_detect_department,
    auto_detect_counter,
    map_to_gr_row,
    _build_workbook_for_docs,
    LR_FORMAT_49_HEADERS,
    api_get_master_manifest,
    api_get_master_counters
)

class TestFiveChangesBackend(unittest.TestCase):

    # ---------------------------------------------------------
    # 1. Manifest and Counter Master Data Loading & Exact Preservations
    # ---------------------------------------------------------
    def test_load_manifest_exact_values(self):
        manifest_map = _load_manifest_data()
        self.assertGreater(len(manifest_map), 0, "Manifest map should not be empty")
        self.assertIn("HIMALAYA WELLNESS COMPANY", manifest_map)

        him_depts = manifest_map["HIMALAYA WELLNESS COMPANY"]
        # Verify exact string preservation including trailing space
        self.assertIn("HIMALAYA-ZIRAKPUR ", him_depts, "Trailing space in HIMALAYA-ZIRAKPUR must be preserved")
        self.assertIn("HIMALAYA-SILIGURI", him_depts)
        self.assertIn("HIM - TUMKUR", him_depts)
        self.assertIn("HIMALAYA - VIJAYAWADA", him_depts)

        # Ensure synthetic/hardcoded departments do NOT exist
        self.assertNotIn("CIPLA-MUMBAI", him_depts)

    def test_load_counters_exact_col1(self):
        counters = _load_counters_data()
        self.assertGreater(len(counters), 0, "Counters list should not be empty")

        # Verify real counters from Col 1
        self.assertIn("DELHI", counters)
        self.assertIn("KOL", counters)
        self.assertIn("MUMBAI 01", counters)
        self.assertIn("BANG-01", counters)
        self.assertIn("1", counters)

        # Verify Branch names from Col 4 are EXCLUDED (no pollution in counter dropdown list)
        self.assertNotIn("KOLKATA", counters, "Branch name KOLKATA must not be in counter list")
        self.assertNotIn("BANGLORE", counters, "Branch name BANGLORE must not be in counter list")
        self.assertNotIn("delhi", counters, "Lower-case fallback 'delhi' must not be in counter list")

    def test_validation_department_and_counter(self):
        # Valid checks
        self.assertTrue(validate_department_exact("HIMALAYA-ZIRAKPUR ", "HIMALAYA WELLNESS COMPANY"))
        self.assertTrue(validate_department_exact("HIMALAYA-SILIGURI", "HIMALAYA WELLNESS COMPANY"))
        self.assertTrue(validate_counter_exact("DELHI"))
        self.assertTrue(validate_counter_exact("MUMBAI 01"))

        # Invalid checks (must reject)
        self.assertFalse(validate_department_exact("INVALID_DEPT", "HIMALAYA WELLNESS COMPANY"))
        self.assertFalse(validate_department_exact("HIMALAYA-ZIRAKPUR", "HIMALAYA WELLNESS COMPANY")) # missing space
        self.assertFalse(validate_counter_exact("INVALID_COUNTER"))
        self.assertFalse(validate_counter_exact("delhi"))
        self.assertFalse(validate_counter_exact("KOLKATA"))

    # ---------------------------------------------------------
    # 2. Department & Counter Auto-Detection from LR Clues
    # ---------------------------------------------------------
    def test_auto_detect_department_unique_match(self):
        # Unique match preserving exact original string including trailing space
        matched = auto_detect_department(
            customer="HIMALAYA WELLNESS COMPANY",
            destination="ZIRAKPUR",
            dept_raw="",
            consignee=""
        )
        self.assertEqual(matched, "HIMALAYA-ZIRAKPUR ", "Must match unique department and preserve trailing space")

        # Match via raw department clue
        matched_sili = auto_detect_department(
            customer="HIMALAYA WELLNESS COMPANY",
            destination="",
            dept_raw="SILIGURI",
            consignee=""
        )
        self.assertEqual(matched_sili, "HIMALAYA-SILIGURI")

    def test_auto_detect_department_unmatched_and_ambiguous_returns_empty(self):
        # Unmatched destination / dept
        unmatched = auto_detect_department(
            customer="HIMALAYA WELLNESS COMPANY",
            destination="LONDON",
            dept_raw="UNKNOWN_ZONE",
            consignee=""
        )
        self.assertEqual(unmatched, "", "Unmatched department must return empty string without guessing")

        # Generic customer token without destination clue must return empty string
        ambiguous = auto_detect_department(
            customer="HIMALAYA WELLNESS COMPANY",
            destination="HIMALAYA",
            dept_raw="",
            consignee=""
        )
        self.assertEqual(ambiguous, "", "Ambiguous match with multiple candidates must return empty string")

    def test_auto_detect_counter_unique_match(self):
        # Exact match
        matched_del = auto_detect_counter(counter_raw="DELHI")
        self.assertEqual(matched_del, "DELHI")

        # Clue match from counter_raw
        matched_mum = auto_detect_counter(counter_raw="MUMBAI 01")
        self.assertEqual(matched_mum, "MUMBAI 01")

        # Branch clue from BookingCounterMast.xlsx Row 3 (Branch 'KOLKATA' -> Counter 'KOL')
        matched_kol = auto_detect_counter(branch_raw="KOLKATA")
        self.assertEqual(matched_kol, "KOL")

    def test_auto_detect_counter_unmatched_returns_empty(self):
        # Genuine unmatched counter or branch not in BookingCounterMast.xlsx
        unmatched_rand = auto_detect_counter(counter_raw="RANDOM_XYZ", branch_raw="UNKNOWN_STATION")
        self.assertEqual(unmatched_rand, "", "Unmatched counter must return empty string")

        unmatched_city = auto_detect_counter(counter_raw="PARIS", branch_raw="LONDON")
        self.assertEqual(unmatched_city, "", "Unmatched location must return empty string without guessing")

    # ---------------------------------------------------------
    # 3. Mandatory Freight Validation
    # ---------------------------------------------------------
    def test_freight_mandatory_export_blocked_when_empty(self):
        doc_no_freight = {
            "Customer Name *": "HIMALAYA WELLNESS COMPANY",
            "Depatment Name": "HIMALAYA-SILIGURI",
            "Counter": "DELHI",
            "freight  *": "",
        }
        with self.assertRaises(HTTPException) as ctx:
            _build_workbook_for_docs([doc_no_freight])
        self.assertEqual(ctx.exception.status_code, 400)
        self.assertIn("Freight is mandatory", ctx.exception.detail)

    def test_freight_export_succeeds_when_manually_entered(self):
        doc_with_freight = {
            "Customer Name *": "HIMALAYA WELLNESS COMPANY",
            "Depatment Name": "HIMALAYA-SILIGURI",
            "Counter": "DELHI",
            "freight  *": "4200.00",
            "product_type": "Surface-FTL",
            "productcode": "PRD-ITEM-99",
        }
        wb, bytes_data, filename, export_id = _build_workbook_for_docs([doc_with_freight])
        self.assertIsNotNone(wb)
        self.assertGreater(len(bytes_data), 0)

        # Check mapped row value in Col 25 (Freight)
        row = map_to_gr_row(doc_with_freight, LR_FORMAT_49_HEADERS)
        self.assertEqual(float(row[25]), 4200.0)

    # ---------------------------------------------------------
    # 4. Product Code and Product Type Separation
    # ---------------------------------------------------------
    def test_product_code_and_product_type_remain_separate(self):
        doc = {
            "Customer Name *": "HIMALAYA WELLNESS COMPANY",
            "Depatment Name": "HIMALAYA-SILIGURI",
            "Counter": "DELHI",
            "product_type": "Global-TT",
            "productcode": "ITEM-CODE-5544",
            "freight  *": "1800",
        }
        row = map_to_gr_row(doc, LR_FORMAT_49_HEADERS)

        # Col 14 (ProductName) receives Product Type
        self.assertEqual(row[14], "Global-TT")

        # Verify that actual Product Code is preserved and NOT overwritten by Product Type
        self.assertEqual(doc["productcode"], "ITEM-CODE-5544")
        self.assertEqual(doc["product_type"], "Global-TT")

    # ---------------------------------------------------------
    # 5. GST Space Validation & Cleanliness
    # ---------------------------------------------------------
    def test_map_to_gr_row_gst_cleanliness(self):
        doc = {
            "Customer Name *": "HIMALAYA WELLNESS COMPANY",
            "Depatment Name": "HIMALAYA-SILIGURI",
            "Counter": "DELHI",
            "cngrgstno *": " 07 AAAAA 0000 A 1 Z 5 ",
            "cngegstno *": " 29 BBBBB 1111 B 2 Z 9 ",
            "product_type": "Global-TT",
            "freight  *": "3500.00",
            "grno (*)": "88412",
        }
        row = map_to_gr_row(doc, LR_FORMAT_49_HEADERS)
        
        # Col 11: ConsignorGST (must be space-free)
        self.assertEqual(row[11], "07AAAAA0000A1Z5")
        self.assertNotIn(" ", row[11])
        # Col 13: ConsigneeGST (must be space-free)
        self.assertEqual(row[13], "29BBBBB1111B2Z9")
        self.assertNotIn(" ", row[13])

    def test_api_endpoints_manifest_and_counters(self):
        data_m = asyncio.run(api_get_master_manifest())
        self.assertTrue(data_m.get("success"))
        self.assertIn("HIMALAYA WELLNESS COMPANY", data_m.get("mapping", {}))
        self.assertIn("HIMALAYA-ZIRAKPUR ", data_m["mapping"]["HIMALAYA WELLNESS COMPANY"])

        data_c = asyncio.run(api_get_master_counters())
        self.assertTrue(data_c.get("success"))
        self.assertIn("DELHI", data_c.get("counters", []))
        self.assertIn("MUMBAI 01", data_c.get("counters", []))
        self.assertNotIn("KOLKATA", data_c.get("counters", []))

if __name__ == "__main__":
    unittest.main()
