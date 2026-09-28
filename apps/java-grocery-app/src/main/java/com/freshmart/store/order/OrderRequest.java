package com.freshmart.store.order;

import java.util.ArrayList;
import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;

/** What the browser sends when a shopper presses "Place order". */
public class OrderRequest {

    @NotEmpty
    @Valid
    private List<Line> items = new ArrayList<Line>();

    public List<Line> getItems() { return items; }
    public void setItems(List<Line> items) { this.items = items; }

    public static class Line {
        @NotNull
        private Long productId;
        @Min(1)
        private int quantity = 1;

        public Long getProductId() { return productId; }
        public void setProductId(Long productId) { this.productId = productId; }
        public int getQuantity() { return quantity; }
        public void setQuantity(int quantity) { this.quantity = quantity; }
    }
}
