package com.freshmart.store.order;

import java.util.List;

import jakarta.validation.Valid;

import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.freshmart.store.web.CurrentUser;

/**
 * Orders (receipts).
 *   POST /api/orders          any logged-in person places an order
 *   GET  /api/orders/mine     my own receipts
 *   GET  /api/orders          cashier/manager: every receipt (the register line)
 *   POST /api/orders/{id}/pay cashier/manager: mark as paid
 */
@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderService orderService;
    private final OrderRepository orders;

    public OrderController(OrderService orderService, OrderRepository orders) {
        this.orderService = orderService;
        this.orders = orders;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public PurchaseOrder place(@Valid @RequestBody OrderRequest request, Authentication auth) {
        return orderService.place(CurrentUser.username(auth), request);
    }

    @GetMapping("/mine")
    public List<PurchaseOrder> mine(Authentication auth) {
        return orders.findByCustomerOrderByCreatedAtDesc(CurrentUser.username(auth));
    }

    @GetMapping
    @PreAuthorize("hasAnyRole('cashier', 'manager')")
    public List<PurchaseOrder> all() {
        return orders.findAllByOrderByCreatedAtDesc();
    }

    @PostMapping("/{id}/pay")
    @PreAuthorize("hasAnyRole('cashier', 'manager')")
    public PurchaseOrder pay(@PathVariable("id") Long id, Authentication auth) {
        return orderService.pay(id, CurrentUser.username(auth));
    }
}
