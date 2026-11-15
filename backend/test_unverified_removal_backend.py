import unittest
import os
import sys

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

import user_cloud_service

class TestUnverifiedRemovalBackend(unittest.TestCase):
    def setUp(self):
        self.test_mobile = "9999888877"
        self.other_mobile = "8888777766"
        # Reset test DB
        user_cloud_service._save_user_db(self.test_mobile, {
            "user_mobile": self.test_mobile,
            "active_batch": [],
            "uploaded_lrs": [],
            "generated_excels": [],
            "dismissed_uploads": []
        })
        user_cloud_service._save_user_db(self.other_mobile, {
            "user_mobile": self.other_mobile,
            "active_batch": [],
            "uploaded_lrs": [],
            "generated_excels": [],
            "dismissed_uploads": []
        })

    def tearDown(self):
        # Clean up test files
        p1 = user_cloud_service._get_user_db_path(self.test_mobile)
        p2 = user_cloud_service._get_user_db_path(self.other_mobile)
        for p in (p1, p2):
            if os.path.exists(p):
                try:
                    os.remove(p)
                except Exception:
                    pass

    def test_delete_unverified_lr_record_clears_active_batch_and_history(self):
        """Test that delete_user_lr_record completely removes an unverified LR from active_batch AND uploaded_lrs."""
        # Seed user database with an unverified active LR and a verified active LR
        user_cloud_service.save_user_active_batch(self.test_mobile, [
            {
                "id": "unverified-doc-123",
                "filename": "lr_unverified.pdf",
                "saved_filename": "LR_20261115_unverified.pdf",
                "data": {"LR No *": "55001", "Customer Name *": "Test Unverified"},
                "is_verified": False,
                "pending_verification": True
            },
            {
                "id": "verified-doc-456",
                "filename": "lr_verified.pdf",
                "saved_filename": "LR_20261115_verified.pdf",
                "data": {"LR No *": "55002", "Customer Name *": "Test Verified"},
                "is_verified": True
            }
        ])

        user_cloud_service.record_uploaded_lr(self.test_mobile, {
            "id": "unverified-doc-123",
            "filename": "lr_unverified.pdf",
            "saved_filename": "LR_20261115_unverified.pdf",
            "lrNo": "55001"
        })

        # Verify initial state: both documents are in active_batch and uploaded_lrs
        data_before = user_cloud_service.get_user_cloud_data(self.test_mobile)
        self.assertEqual(len(data_before["active_batch"]), 2)
        self.assertEqual(len(data_before["uploaded_lrs"]), 2)

        # Call delete_user_lr_record for the unverified document
        res = user_cloud_service.delete_user_lr_record(
            mobile=self.test_mobile,
            lr_identifiers=["unverified-doc-123", "lr_unverified.pdf", "LR_20261115_unverified.pdf"]
        )
        self.assertTrue(res["success"])
        self.assertEqual(res["removed_from_active"], 1)
        self.assertEqual(res["removed_from_uploads"], 1)

        # Confirm unverified LR is completely gone from active_batch and uploaded_lrs,
        # while the verified LR remains in both!
        data_after = user_cloud_service.get_user_cloud_data(self.test_mobile)
        self.assertEqual(len(data_after["active_batch"]), 1)
        self.assertEqual(data_after["active_batch"][0]["id"], "verified-doc-456", "Verified LR must be retained")
        self.assertEqual(len(data_after["uploaded_lrs"]), 1, "Verified LR must be retained in uploaded_lrs")
        self.assertEqual(data_after["uploaded_lrs"][0]["id"], "verified-doc-456")
        self.assertIn("unverified-doc-123", data_after["dismissed_uploads"])

    def test_delete_upload_history_preserves_verified_active_batch(self):
        """Test that delete_user_upload_history ONLY removes from history, leaving verified active_batch intact."""
        user_cloud_service.save_user_active_batch(self.test_mobile, [
            {
                "id": "verified-doc-456",
                "filename": "lr_verified.pdf",
                "saved_filename": "LR_20261115_verified.pdf",
                "data": {"LR No *": "55002", "Customer Name *": "Test Verified"},
                "is_verified": True
            }
        ])
        user_cloud_service.record_uploaded_lr(self.test_mobile, {
            "id": "verified-doc-456",
            "filename": "lr_verified.pdf",
            "saved_filename": "LR_20261115_verified.pdf",
            "lrNo": "55002"
        })

        # Call delete_user_upload_history (simulate dismissing verified LR from history strip)
        res = user_cloud_service.delete_user_upload_history(
            mobile=self.test_mobile,
            lr_identifiers=["verified-doc-456", "lr_verified.pdf"]
        )
        self.assertTrue(res["success"])

        # Confirm active_batch is 100% PRESERVED
        data = user_cloud_service.get_user_cloud_data(self.test_mobile)
        self.assertEqual(len(data["active_batch"]), 1, "Verified LR in active_batch (Step 3) must NOT be deleted")
        self.assertEqual(len(data["uploaded_lrs"]), 0, "Uploaded history must be cleared")

    def test_user_isolation_is_strictly_preserved(self):
        """Test that removing an LR for User A does not affect User B."""
        user_cloud_service.save_user_active_batch(self.test_mobile, [
            {"id": "doc-a", "filename": "lr_a.pdf", "data": {"LR No *": "111"}}
        ])
        user_cloud_service.save_user_active_batch(self.other_mobile, [
            {"id": "doc-b", "filename": "lr_b.pdf", "data": {"LR No *": "222"}}
        ])

        user_cloud_service.delete_user_lr_record(self.test_mobile, ["doc-a"])

        user_a_data = user_cloud_service.get_user_cloud_data(self.test_mobile)
        user_b_data = user_cloud_service.get_user_cloud_data(self.other_mobile)

        self.assertEqual(len(user_a_data["active_batch"]), 0)
        self.assertEqual(len(user_b_data["active_batch"]), 1, "User B's data must remain intact")
        self.assertEqual(user_b_data["active_batch"][0]["id"], "doc-b")

if __name__ == "__main__":
    unittest.main()
