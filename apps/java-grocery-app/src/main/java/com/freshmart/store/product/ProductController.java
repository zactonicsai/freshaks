package com.freshmart.store.product;

import java.util.List;
import java.util.NoSuchElementException;

import jakarta.validation.Valid;

import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.freshmart.store.activity.ActivityService;
import com.freshmart.store.web.CurrentUser;

/** The shelves. Anyone logged in can look; only managers can restock or change prices. */
@RestController
@RequestMapping("/api/products")
public class ProductController {

    private final ProductRepository products;
    private final ActivityService activity;

    public ProductController(ProductRepository products, ActivityService activity) {
        this.products = products;
        this.activity = activity;
    }

    @GetMapping
    public List<Product> list() {
        return products.findAllByOrderByNameAsc();
    }

    @GetMapping("/{id}")
    public Product one(@PathVariable("id") Long id) {
        return products.findById(id).orElseThrow(() -> new NoSuchElementException("No product " + id));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasRole('manager')")
    public Product create(@Valid @RequestBody Product product, Authentication auth) {
        Product saved = products.save(product);
        activity.log(CurrentUser.username(auth), "PRODUCT_CREATED", "product=" + saved.getName()
                + " price=" + saved.getPrice() + " stock=" + saved.getStock());
        return saved;
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasRole('manager')")
    public Product update(@PathVariable("id") Long id, @Valid @RequestBody Product changes, Authentication auth) {
        Product existing = one(id);
        existing.setName(changes.getName());
        existing.setEmoji(changes.getEmoji());
        existing.setPrice(changes.getPrice());
        existing.setStock(changes.getStock());
        Product saved = products.save(existing);
        activity.log(CurrentUser.username(auth), "PRODUCT_UPDATED", "product=" + saved.getName()
                + " price=" + saved.getPrice() + " stock=" + saved.getStock());
        return saved;
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasRole('manager')")
    public void delete(@PathVariable("id") Long id, Authentication auth) {
        Product existing = one(id);
        products.delete(existing);
        activity.log(CurrentUser.username(auth), "PRODUCT_DELETED", "product=" + existing.getName());
    }
}
