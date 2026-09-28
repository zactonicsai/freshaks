package com.freshmart.store.report;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.data.domain.PageRequest;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.freshmart.store.order.OrderRepository;
import com.freshmart.store.product.ProductRepository;

/** The manager's report card: sales, receipts waiting at the register, best sellers. */
@RestController
@RequestMapping("/api/reports")
public class ReportController {

    private final OrderRepository orders;
    private final ProductRepository products;

    public ReportController(OrderRepository orders, ProductRepository products) {
        this.orders = orders;
        this.products = products;
    }

    @GetMapping("/sales")
    @PreAuthorize("hasRole('manager')")
    public Map<String, Object> sales() {
        Map<String, Object> report = new LinkedHashMap<String, Object>();
        long newOrders = 0;
        long paidOrders = 0;
        BigDecimal revenue = BigDecimal.ZERO;
        BigDecimal waiting = BigDecimal.ZERO;
        List<OrderRepository.StatusSummary> rows = orders.summarizeByStatus();
        for (OrderRepository.StatusSummary row : rows) {
            if ("PAID".equals(row.getStatus())) {
                paidOrders = row.getOrders();
                revenue = row.getRevenue();
            } else {
                newOrders += row.getOrders();
                waiting = waiting.add(row.getRevenue());
            }
        }
        report.put("paidOrders", paidOrders);
        report.put("revenue", revenue);
        report.put("newOrders", newOrders);
        report.put("waitingAtRegister", waiting);
        report.put("productsOnShelf", products.count());
        report.put("topProducts", orders.topProducts(PageRequest.of(0, 5)));
        return report;
    }
}
