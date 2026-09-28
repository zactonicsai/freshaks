package com.freshmart.store.order;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.NoSuchElementException;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.freshmart.store.activity.ActivityService;
import com.freshmart.store.product.Product;
import com.freshmart.store.product.ProductRepository;

/** The rules of the store: placing an order takes items off the shelf; paying closes the receipt. */
@Service
public class OrderService {

    private final OrderRepository orders;
    private final ProductRepository products;
    private final ActivityService activity;

    public OrderService(OrderRepository orders, ProductRepository products, ActivityService activity) {
        this.orders = orders;
        this.products = products;
        this.activity = activity;
    }

    @Transactional
    public PurchaseOrder place(String customer, OrderRequest request) {
        PurchaseOrder order = new PurchaseOrder();
        order.setCustomer(customer);
        BigDecimal total = BigDecimal.ZERO;
        for (OrderRequest.Line line : request.getItems()) {
            final Long productId = line.getProductId();
            Product product = products.findById(productId)
                    .orElseThrow(() -> new IllegalArgumentException("Unknown product " + productId));
            int quantity = line.getQuantity();
            if (quantity < 1) {
                throw new IllegalArgumentException("Quantity must be at least 1");
            }
            if (product.getStock() < quantity) {
                throw new IllegalArgumentException("Not enough " + product.getName() + " on the shelf (only "
                        + product.getStock() + " left)");
            }
            product.setStock(product.getStock() - quantity);
            products.save(product);

            OrderItem item = new OrderItem();
            item.setOrder(order);
            item.setProduct(product);
            item.setQuantity(quantity);
            item.setUnitPrice(product.getPrice());
            order.getItems().add(item);
            total = total.add(item.getLineTotal());
        }
        if (order.getItems().isEmpty()) {
            throw new IllegalArgumentException("The basket is empty");
        }
        order.setTotal(total);
        PurchaseOrder saved = orders.save(order);
        activity.log(customer, "ORDER_PLACED", "order=" + saved.getId() + " items=" + saved.getItems().size()
                + " total=" + saved.getTotal());
        return saved;
    }

    @Transactional
    public PurchaseOrder pay(Long orderId, String cashier) {
        PurchaseOrder order = orders.findById(orderId)
                .orElseThrow(() -> new NoSuchElementException("No order " + orderId));
        if (PurchaseOrder.STATUS_PAID.equals(order.getStatus())) {
            throw new IllegalArgumentException("Order " + orderId + " is already paid");
        }
        order.setStatus(PurchaseOrder.STATUS_PAID);
        order.setPaidAt(Instant.now());
        order.setPaidBy(cashier);
        PurchaseOrder saved = orders.save(order);
        activity.log(cashier, "ORDER_PAID", "order=" + saved.getId() + " customer=" + saved.getCustomer()
                + " total=" + saved.getTotal());
        return saved;
    }
}
