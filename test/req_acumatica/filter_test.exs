defmodule ReqAcumatica.FilterTest do
  use ExUnit.Case, async: true

  import ReqAcumatica.Filter

  describe "comparison operators" do
    test "eq with string value" do
      assert "#{eq("Status", "Open")}" == "Status eq 'Open'"
    end

    test "eq with integer value" do
      assert "#{eq("OrderTotal", 1000)}" == "OrderTotal eq 1000"
    end

    test "ne with string" do
      assert "#{ne("Status", "Closed")}" == "Status ne 'Closed'"
    end

    test "gt with number" do
      assert "#{gt("Amount", 500)}" == "Amount gt 500"
    end

    test "ge with number" do
      assert "#{ge("Qty", 10)}" == "Qty ge 10"
    end

    test "lt with number" do
      assert "#{lt("Price", 99.99)}" == "Price lt 99.99"
    end

    test "le with number" do
      assert "#{le("Count", 0)}" == "Count le 0"
    end

    test "eq with boolean" do
      assert "#{eq("Active", true)}" == "Active eq true"
    end

    test "eq with nil" do
      assert "#{eq("DeletedAt", nil)}" == "DeletedAt eq null"
    end
  end

  describe "string functions" do
    test "contains" do
      assert "#{contains("Name", "Newlight")}" == "contains(Name, 'Newlight')"
    end

    test "startswith" do
      assert "#{startswith("OrderNbr", "SO")}" == "startswith(OrderNbr, 'SO')"
    end

    test "endswith" do
      assert "#{endswith("Email", ".com")}" == "endswith(Email, '.com')"
    end
  end

  describe "logical combinators" do
    test "and_filter" do
      filter =
        eq("Status", "Open")
        |> and_filter(gt("Total", 100))

      assert "#{filter}" == "Status eq 'Open' and Total gt 100"
    end

    test "or_filter wraps in parens" do
      filter =
        eq("Status", "Open")
        |> or_filter(eq("Status", "Hold"))

      assert "#{filter}" == "(Status eq 'Open') or (Status eq 'Hold')"
    end

    test "not_filter" do
      filter = not_filter(eq("Status", "Closed"))
      assert "#{filter}" == "not (Status eq 'Closed')"
    end

    test "chained compound filter" do
      filter =
        eq("Status", "Open")
        |> and_filter(gt("OrderTotal", 1000))
        |> and_filter(contains("CustomerName", "Newlight"))

      assert "#{filter}" ==
               "Status eq 'Open' and OrderTotal gt 1000 and contains(CustomerName, 'Newlight')"
    end
  end

  describe "null checks" do
    test "is_null" do
      assert "#{is_null("ShipDate")}" == "ShipDate eq null"
    end

    test "is_not_null" do
      assert "#{is_not_null("ShipDate")}" == "ShipDate ne null"
    end
  end

  describe "escaping" do
    test "escapes single quotes in strings" do
      assert "#{eq("Name", "O'Brien")}" == "Name eq 'O''Brien'"
    end
  end
end
