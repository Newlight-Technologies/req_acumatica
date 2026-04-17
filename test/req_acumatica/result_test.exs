defmodule ReqAcumatica.ResultTest do
  use ExUnit.Case, async: true

  alias ReqAcumatica.Result

  describe "from_odata_response/1" do
    test "parses OData v4 format" do
      body = %{
        "value" => [
          %{"OrderNbr" => "SO-001", "Status" => "Open"},
          %{"OrderNbr" => "SO-002", "Status" => "Hold"}
        ],
        "@odata.count" => 42
      }

      result = Result.from_odata_response(body)

      assert length(result.rows) == 2
      assert result.count == 42
      assert hd(result.rows)["OrderNbr"] == "SO-001"
    end

    test "parses OData v4 with next link" do
      body = %{
        "value" => [%{"id" => 1}],
        "@odata.nextLink" => "https://example.com/odata/GI?$skip=200"
      }

      result = Result.from_odata_response(body)

      assert result.next_link == "https://example.com/odata/GI?$skip=200"
    end

    test "parses OData v3 format with d.results" do
      body = %{
        "d" => %{
          "results" => [
            %{"ItemID" => "WIDGET-A", "Qty" => 100}
          ]
        }
      }

      result = Result.from_odata_response(body)

      assert length(result.rows) == 1
      assert hd(result.rows)["ItemID"] == "WIDGET-A"
    end

    test "parses OData v3 format with d as list" do
      body = %{
        "d" => [
          %{"ItemID" => "WIDGET-A"}
        ]
      }

      result = Result.from_odata_response(body)

      assert length(result.rows) == 1
    end

    test "handles plain list" do
      body = [%{"a" => 1}, %{"a" => 2}]

      result = Result.from_odata_response(body)

      assert length(result.rows) == 2
    end

    test "handles empty value array" do
      body = %{"value" => []}

      result = Result.from_odata_response(body)

      assert result.rows == []
      assert result.count == 0
    end

    test "handles unexpected format gracefully" do
      body = %{"error" => "something went wrong"}

      result = Result.from_odata_response(body)

      assert result.rows == []
      assert result.count == 0
      assert result.raw == body
    end

    test "parses JSON string input" do
      json = Jason.encode!(%{"value" => [%{"x" => 1}]})

      result = Result.from_odata_response(json)

      assert length(result.rows) == 1
    end
  end
end
