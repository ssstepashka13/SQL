from dataclasses import dataclass
from decimal import Decimal

import psycopg
from prompt_toolkit import prompt
from prompt_toolkit.shortcuts import choice
from psycopg.rows import class_row
from rich.panel import Panel
from rich.table import Table

from console import console, render_error
from db import get_conn
from validators import (
    MaxLengthValidator,
    NonEmptyValidator,
    PriceValidator,
    YesNoValidator,
)
from auth import ALL_ROLES, ROLE_CATALOG_MANAGER
from commands import command, CATEGORY_PRODUCTS

SKU_MAX_LENGTH = 30


@dataclass
class Product:
    id: int
    sku: str
    name: str
    price: Decimal
    category: str


def _render_product(product: Product) -> None:
    """Отображает информацию о продукте в виде таблицы внутри панели."""
    table = Table(show_header=False, box=None, padding=(0, 2))

    table.add_column("Поле", style="bold cyan", width=15)
    table.add_column("Значение", style="white")

    table.add_row("ID", str(product.id))
    table.add_row("SKU", product.sku)
    table.add_row("Название", product.name)
    table.add_row("Цена", f"{product.price:.2f}")
    table.add_row("Категория", product.category)

    panel = Panel(
        table,
        expand=False,
        title=f"[bold green]Товар #{product.id}[/bold green]",
        border_style="green",
    )

    console.print(panel)


_SELECT_PRODUCT = """
    SELECT p.id, p.sku, p.name, p.price, c.name AS category
    FROM catalog.products p
    JOIN catalog.product_categories c ON c.id = p.category_id
"""


def _find_product(_id: str) -> Product | None:
    conn = get_conn()
    with conn.cursor(row_factory=class_row(Product)) as cur:
        cur.execute(_SELECT_PRODUCT + " WHERE p.id = %s", (_id,))
        return cur.fetchone()


def _load_categories() -> dict[str, int]:
    """Возвращает отображение название категории -> id для выбора при вводе."""
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("SELECT name, id FROM catalog.product_categories ORDER BY name")
        return dict(cur.fetchall())


def _prompt_category(categories: dict[str, int], default: str | None = None) -> int:
    """Выбор категории из списка."""
    options = [(cat_id, name) for name, cat_id in categories.items()]
    default_id = categories.get(default) if default else None
    return choice("Категория:", options=options, default=default_id)


@command(
    "list products",
    "список всех товаров",
    CATEGORY_PRODUCTS,
    list(ALL_ROLES),
)
def list_products() -> None:
    """Выводит список всех продуктов из таблицы catalog.products."""
    conn = get_conn()
    table = Table(title="Товары", show_header=True, header_style="bold cyan")

    table.add_column("ID", style="dim", width=6, justify="right")
    table.add_column("SKU", style="cyan", min_width=12)
    table.add_column("Название", style="green", min_width=20)
    table.add_column("Цена", style="yellow", justify="right", min_width=10)
    table.add_column("Категория", style="magenta", min_width=15)

    with conn.cursor(row_factory=class_row(Product)) as cur:
        cur.execute(_SELECT_PRODUCT + " ORDER BY p.id")
        products: list[Product] = cur.fetchall()

    for product in products:
        table.add_row(
            str(product.id),
            product.sku,
            product.name,
            f"{product.price:.2f}",
            product.category,
        )
    console.print(table)


@command(
    "show product",
    "информация о товаре",
    CATEGORY_PRODUCTS,
    list(ALL_ROLES),
)
def show_product(_id: str) -> None:
    """Показывает детальную информацию о продукте по его ID."""
    product = _find_product(_id)
    if product is None:
        render_error(f"Товар с ID {_id} не найден")
        return
    _render_product(product)


@command(
    "add product",
    "добавить товар (интерактивно)",
    CATEGORY_PRODUCTS,
    [ROLE_CATALOG_MANAGER],
)
def add_product() -> None:
    """Добавляет новый продукт в базу данных."""
    conn = get_conn()

    categories = _load_categories()
    if not categories:
        render_error(
            "Нет ни одной категории. Сначала добавьте категорию: add product_category"
        )
        return

    sku = prompt(
        "SKU: ",
        validator=MaxLengthValidator(
            SKU_MAX_LENGTH,
            message=f"SKU не может быть пустым и длиннее {SKU_MAX_LENGTH} символов",
        ),
    ).strip()
    if not sku:
        render_error("SKU не может быть пустым")
        return
    name = prompt("Название: ", validator=NonEmptyValidator()).strip()
    price = Decimal(prompt("Цена: ", validator=PriceValidator()).strip())
    category_id = _prompt_category(categories)

    try:
        conn.execute(
            """INSERT INTO catalog.products (sku, name, price, category_id)
            VALUES (%s, %s, %s, %s)""",
            (sku, name, price, category_id),
        )
    except psycopg.errors.UniqueViolation:
        render_error(f"Товар с SKU {sku} уже существует")
        return
    console.print(f"[green]Товар {name} (SKU {sku}) добавлен[/green]")


@command(
    "edit product",
    "редактировать товар",
    CATEGORY_PRODUCTS,
    [ROLE_CATALOG_MANAGER],
)
def edit_product(_id: str) -> None:
    """Редактирует существующий продукт."""
    conn = get_conn()
    product = _find_product(_id)
    if product is None:
        render_error(f"Товар с ID {_id} не найден")
        return

    categories = _load_categories()

    sku = prompt(
        "SKU: ",
        default=product.sku,
        validator=MaxLengthValidator(
            SKU_MAX_LENGTH,
            message=f"SKU не может быть пустым и длиннее {SKU_MAX_LENGTH} символов",
        ),
    ).strip()
    if not sku:
        render_error("SKU не может быть пустым")
        return
    name = prompt(
        "Название: ", default=product.name, validator=NonEmptyValidator()
    ).strip()
    price = Decimal(
        prompt(
            "Цена: ", default=f"{product.price:.2f}", validator=PriceValidator()
        ).strip()
    )
    category_id = _prompt_category(categories, default=product.category)

    try:
        conn.execute(
            """UPDATE catalog.products
            SET sku = %s, name = %s, price = %s, category_id = %s
            WHERE id = %s""",
            (sku, name, price, category_id, _id),
        )
    except psycopg.errors.UniqueViolation:
        render_error(f"Товар с SKU {sku} уже существует")
        return
    console.print(f"[green]Товар {name} (SKU {sku}) обновлен[/green]")


@command(
    "delete product",
    "удалить товар",
    CATEGORY_PRODUCTS,
    [ROLE_CATALOG_MANAGER],
)
def delete_product(_id: str) -> None:
    """Удаляет продукт из базы данных."""
    conn = get_conn()
    product = _find_product(_id)
    if product is None:
        render_error(f"Товар с ID {_id} не найден")
        return

    _render_product(product)

    answer = prompt("Вы уверены? (y/n, д/н): ", validator=YesNoValidator())
    if not YesNoValidator.is_yes(answer):
        return

    conn.execute("DELETE FROM catalog.products WHERE id = %s", (_id,))
    console.print(f"[green]Товар {product.name} (SKU {product.sku}) удален[/green]")
