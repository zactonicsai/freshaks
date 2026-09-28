-- Starting shelf stock. ON CONFLICT DO NOTHING = do not add twice on restart.
INSERT INTO products (name, emoji, price, stock) VALUES
  ('Apples',        '🍎', 1.25, 100),
  ('Bananas',       '🍌', 0.50, 150),
  ('Milk',          '🥛', 3.49,  40),
  ('Bread',         '🍞', 2.99,  30),
  ('Eggs',          '🥚', 4.20,  60),
  ('Carrots',       '🥕', 1.10,  80),
  ('Cheese',        '🧀', 5.75,  25),
  ('Orange juice',  '🧃', 3.99,  35),
  ('Cereal',        '🥣', 4.50,  45),
  ('Chocolate bar', '🍫', 1.75, 200)
ON CONFLICT (name) DO NOTHING;
