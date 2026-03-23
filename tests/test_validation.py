"""Tests for the validation check runner."""
import pytest
from unittest.mock import MagicMock

from scripts.validate_refresh import run_check, CheckResult


class TestRunCheck:
    def test_passing_check_returns_zero_rows(self):
        cursor = MagicMock()
        cursor.fetchall.return_value = []
        result = run_check(cursor, "test_check", "SELECT 1 WHERE 1=0")
        assert result.passed is True
        assert result.row_count == 0

    def test_failing_check_returns_rows(self):
        cursor = MagicMock()
        cursor.fetchall.return_value = [("orphan_row",)]
        result = run_check(cursor, "orphan_check", "SELECT * FROM orphans")
        assert result.passed is False
        assert result.row_count == 1

    def test_exception_returns_failure(self):
        cursor = MagicMock()
        cursor.execute.side_effect = Exception("connection lost")
        result = run_check(cursor, "broken_check", "SELECT 1")
        assert result.passed is False
        assert result.row_count == -1
        assert "connection lost" in result.detail

    def test_multiple_failures_counted(self):
        cursor = MagicMock()
        cursor.fetchall.return_value = [("dup1",), ("dup2",), ("dup3",)]
        result = run_check(cursor, "dup_check", "SELECT * FROM dups")
        assert result.passed is False
        assert result.row_count == 3
