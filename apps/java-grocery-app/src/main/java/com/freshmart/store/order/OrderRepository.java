package com.freshmart.store.order;

import java.math.BigDecimal;
import java.util.List;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

public interface OrderRepository extends JpaRepository<PurchaseOrder, Long> {

    List<PurchaseOrder> findByCustomerOrderByCreatedAtDesc(String customer);

    List<PurchaseOrder> findAllByOrderByCreatedAtDesc();

    /** For the manager's report: how many orders and how much money per status. */
    @Query("select o.status as status, count(o) as orders, sum(o.total) as revenue "
         + "from PurchaseOrder o group by o.status")
    List<StatusSummary> summarizeByStatus();

    /** For the manager's report: best-selling products (pass PageRequest.of(0, 5) for a top-5). */
    @Query("select i.product.name as name, i.product.emoji as emoji, sum(i.quantity) as quantity "
         + "from OrderItem i group by i.product.name, i.product.emoji order by sum(i.quantity) desc")
    List<ProductSales> topProducts(Pageable pageable);

    interface StatusSummary {
        String getStatus();
        Long getOrders();
        BigDecimal getRevenue();
    }

    interface ProductSales {
        String getName();
        String getEmoji();
        Long getQuantity();
    }
}
