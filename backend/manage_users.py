#!/usr/bin/env python3
"""
Developer-Only CLI: User Management System for Box N Freight OCR to Excel.
Provides strictly 4 operations:
  1. Create User
  2. Edit User
  3. Delete User
  4. View User Count

Usage:
  Interactive Menu:
    python backend/manage_users.py

  CLI Direct Commands:
    python backend/manage_users.py --count
    python backend/manage_users.py --create --name "Operator Name" --mobile "9876543210"
    python backend/manage_users.py --edit --mobile "9876543210" [--new-name "New Name"] [--new-mobile "9876543211"]
    python backend/manage_users.py --delete --mobile "9876543210" [--confirm]
"""

import os
import sys
import argparse

# Ensure backend directory is in sys.path
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

import auth_service


def print_banner():
    print("=" * 65)
    print("        BOX N FREIGHT - DEVELOPER USER MANAGEMENT")
    print("=" * 65)


def op_view_count():
    count = auth_service.get_total_users_count()
    print("-" * 65)
    print(f"  Total Registered Users: {count}")
    print("-" * 65)
    return count


def op_create_user(name: str | None = None, mobile: str | None = None):
    print("\n--- [Operation: Create User] ---")
    if not name:
        name = input("Enter User Full Name: ").strip()
    if not mobile:
        mobile = input("Enter 10-Digit Mobile Number (+91): ").strip()

    if not name:
        print("[ERROR] User name cannot be empty.")
        return False
    if not mobile:
        print("[ERROR] Mobile number cannot be empty.")
        return False

    res = auth_service.create_user_record(name=name, mobile_raw=mobile)
    if res.get("success"):
        u = res.get("user", {})
        print(f"\n[SUCCESS] User created successfully!")
        print(f"  ID        : {u.get('id')}")
        print(f"  Name      : {u.get('name')}")
        print(f"  Mobile    : +91 {u.get('mobile')}")
        print(f"  Role      : {u.get('role')}")
        print(f"  Created At: {u.get('created_at')}")
        return True
    else:
        print(f"\n[ERROR] Failed to create user: {res.get('error')}")
        return False


def op_edit_user(
    mobile: str | None = None,
    new_name: str | None = None,
    new_mobile: str | None = None,
    interactive: bool = True
):
    print("\n--- [Operation: Edit User] ---")
    if not mobile:
        mobile = input("Enter existing user's 10-digit mobile number: ").strip()

    user = auth_service.get_user_by_mobile(mobile)
    if not user:
        print(f"[ERROR] User with mobile +91 {mobile} was not found.")
        return False

    print(f"\nFound User:")
    print(f"  Current Name  : {user.get('name')}")
    print(f"  Current Mobile: +91 {user.get('mobile')}")

    if interactive and new_name is None and new_mobile is None:
        print("\nLeave blank to keep current value.")
        input_name = input(f"New Name [{user.get('name')}]: ").strip()
        input_mob = input(f"New Mobile [{user.get('mobile')}]: ").strip()
        new_name = input_name if input_name else None
        new_mobile = input_mob if input_mob else None

    if new_name is None and new_mobile is None:
        print("[INFO] No changes submitted. User remains unchanged.")
        return True

    res = auth_service.edit_user_record(
        mobile_raw=mobile,
        new_name=new_name,
        new_mobile_raw=new_mobile
    )

    if res.get("success"):
        u = res.get("user", {})
        print(f"\n[SUCCESS] User updated successfully!")
        print(f"  Name  : {u.get('name')}")
        print(f"  Mobile: +91 {u.get('mobile')}")
        return True
    else:
        print(f"\n[ERROR] Failed to update user: {res.get('error')}")
        return False


def op_delete_user(mobile: str | None = None, auto_confirm: bool = False):
    print("\n--- [Operation: Delete User] ---")
    if not mobile:
        mobile = input("Enter 10-digit mobile number of user to permanently delete: ").strip()

    user = auth_service.get_user_by_mobile(mobile)
    if not user:
        print(f"[ERROR] User with mobile +91 {mobile} was not found.")
        return False

    print(f"\nSelected User for Deletion:")
    print(f"  Name  : {user.get('name')}")
    print(f"  Mobile: +91 {user.get('mobile')}")
    print(f"  ID    : {user.get('id')}")

    if not auto_confirm:
        confirm = input("\nAre you SURE you want to permanently delete this user? (yes/no): ").strip().lower()
        if confirm not in ("y", "yes"):
            print("[INFO] Deletion cancelled.")
            return False

    res = auth_service.delete_user_record(mobile_raw=mobile, archive_data=True)
    if res.get("success"):
        print(f"\n[SUCCESS] {res.get('message')}")
        return True
    else:
        print(f"\n[ERROR] Failed to delete user: {res.get('error')}")
        return False


def interactive_menu():
    while True:
        print_banner()
        print("  1. Create User")
        print("  2. Edit User")
        print("  3. Delete User")
        print("  4. View User Count")
        print("  5. Exit")
        print("=" * 65)

        choice = input("Select an option [1-5]: ").strip()

        if choice == "1":
            op_create_user()
        elif choice == "2":
            op_edit_user()
        elif choice == "3":
            op_delete_user()
        elif choice == "4":
            op_view_count()
        elif choice in ("5", "q", "exit", "quit"):
            print("\nExiting Developer User Management. Goodbye!\n")
            break
        else:
            print("\n[!] Invalid selection. Please enter a number between 1 and 5.\n")

        input("\nPress [Enter] to return to menu...")


def main():
    parser = argparse.ArgumentParser(
        description="Developer-Only CLI for Box N Freight User Management (Create, Edit, Delete, View Count)."
    )
    parser.add_argument("--count", action="store_true", help="Display total count of registered users")
    parser.add_argument("--create", action="store_true", help="Create a new user")
    parser.add_argument("--name", help="User full name (for --create or --edit)")
    parser.add_argument("--mobile", help="User 10-digit mobile number")
    parser.add_argument("--edit", action="store_true", help="Edit an existing user (specify with --mobile)")
    parser.add_argument("--new-name", help="New user full name (for --edit)")
    parser.add_argument("--new-mobile", help="New 10-digit mobile number (for --edit)")
    parser.add_argument("--delete", action="store_true", help="Delete a user (specify with --mobile)")
    parser.add_argument("--confirm", action="store_true", help="Bypass delete confirmation prompt")

    args = parser.parse_args()

    # If flags are provided, execute single action
    if args.count:
        op_view_count()
        return

    if args.create:
        op_create_user(name=args.name, mobile=args.mobile)
        return

    if args.edit:
        op_edit_user(
            mobile=args.mobile,
            new_name=args.new_name or args.name,
            new_mobile=args.new_mobile,
            interactive=False if (args.new_name or args.new_mobile or args.name) else True
        )
        return

    if args.delete:
        op_delete_user(mobile=args.mobile, auto_confirm=args.confirm)
        return

    # If no arguments given, launch interactive menu
    interactive_menu()


if __name__ == "__main__":
    main()
