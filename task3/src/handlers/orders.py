from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal

from prompt_toolkit import prompt
from prompt_toolkit.completion import WordCompleter
from psycopg.rows import class_row
from rich.panel import Panel
from rich.table import Table

from console import console, render_error
from db import get_conn
from validators import (
    ChoiceValidator,
    PositiveIntValidator,
    PriceValidator,
    YesNoValidator,
)
from commands import command, CATEGORY_ORDERS

UNPUBLISHED = "unpublished"


@dataclass
class Order:
    id: int
    status: str
    total_amount: Decimal
    created_at: datetime
    warehouse_id: int
    warehouse_city: str


@dataclass
class OrderItem:
    product_id: int
    sku: str
    name: str
    price: Decimal
    quantity: int


def _find_order(_id: str) -> Order | None:
    conn = get_conn()
    with conn.cursor(row_factory=class_row(Order)) as cur:
        cur.execute(
            """SELECT o.*, w.city AS warehouse_city
            FROM sales.orders o
            JOIN catalog.warehouses w ON w.id = o.warehouse_id
            WHERE o.id = %s""",
            (_id,),
        )
        return cur.fetchone()


def _load_items(order_id: str) -> list[OrderItem]:
    conn = get_conn()
    with conn.cursor(row_factory=class_row(OrderItem)) as cur:
        cur.execute(
            """SELECT oi.product_id, p.sku, p.name, oi.price, oi.quantity
            FROM sales.order_items oi
            JOIN catalog.products p ON p.id = oi.product_id
            WHERE oi.order_id = %s
            ORDER BY p.sku""",
            (order_id,),
        )
        return cur.fetchall()


def _recalc_total(order_id: str) -> None:
    """Пересчитывает сумму заказа как сумму цен позиций с учетом количества."""
    conn = get_conn()
    conn.execute(
        """UPDATE sales.orders SET total_amount = COALESCE(
            (SELECT SUM(price * quantity) FROM sales.order_items WHERE order_id = %s), 0)
        WHERE id = %s""",
        (order_id, order_id),
    )


def _ensure_unpublished(order: Order) -> bool:
    if order.status != UNPUBLISHED:
        render_error(
            f"Заказ #{order.id} опубликован (статус {order.status}), "
            "его нельзя редактировать или удалять"
        )
        return False
    return True


def _render_order(order: Order) -> None:
    table = Table(show_header=False, box=None, padding=(0, 2))
    table.add_column("Поле", style="bold cyan", width=15)
    table.add_column("Значение", style="white")

    table.add_row("ID", str(order.id))
    table.add_row("Статус", order.status)
    table.add_row("Сумма", f"{order.total_amount:.2f}")
    table.add_row("Создан", order.created_at.strftime("%Y-%m-%d %H:%M"))
    table.add_row("Склад", f"{order.warehouse_id} ({order.warehouse_city})")

    panel = Panel(
        table,
        expand=False,
        title=f"[bold green]Заказ #{order.id}[/bold green]",
        border_style="green",
    )
    console.print(panel)

    items = _load_items(str(order.id))
    if not items:
        console.print("[dim]В заказе пока нет товаров[/dim]")
        return

    items_table = Table(title="Позиции заказа", header_style="bold cyan")
    items_table.add_column("SKU", style="cyan")
    items_table.add_column("Товар", style="green")
    items_table.add_column("Цена", style="yellow", justify="right")
    items_table.add_column("Кол-во", style="magenta", justify="right")
    items_table.add_column("Сумма", style="yellow", justify="right")
    for item in items:
        items_table.add_row(
            item.sku,
            item.name,
            f"{item.price:.2f}",
            str(item.quantity),
            f"{item.price * item.quantity:.2f}",
        )
    console.print(items_table)


def _prompt_warehouse(default: str | None = None) -> int | None:
    """Показывает список складов и просит выбрать id склада отгрузки."""
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("SELECT id, city, label FROM catalog.warehouses ORDER BY id")
        rows = cur.fetchall()
    if not rows:
        render_error("Нет ни одного склада. Сначала добавьте склад: add warehouse")
        return None

    console.print("[dim]Склады:[/dim]")
    for wid, city, label in rows:
        suffix = f" ({label})" if label else ""
        console.print(f"  {wid}: {city}{suffix}")

    ids = [str(wid) for wid, _, _ in rows]
    answer = prompt(
        "Склад отгрузки (id): ",
        default=default or "",
        validator=ChoiceValidator(ids, message="Укажите id склада из списка"),
    ).strip()
    return int(answer)


def _prompt_new_product(order_id: str) -> tuple[int, Decimal] | None:
    """Выбор товара для добавления в заказ (с автодополнением).
    Уже добавленные в заказ товары в список не попадают."""
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute(
            """SELECT p.id, p.sku, p.name, p.price
            FROM catalog.products p
            WHERE p.id NOT IN (
                SELECT product_id FROM sales.order_items WHERE order_id = %s
            )
            ORDER BY p.sku""",
            (order_id,),
        )
        rows = cur.fetchall()
    if not rows:
        render_error("Нет доступных товаров (все уже в заказе)")
        return None

    choices = {f"{sku} - {name}": (pid, price) for pid, sku, name, price in rows}
    keys = list(choices)
    picked = prompt(
        "Товар: ",
        completer=WordCompleter(keys, ignore_case=True, sentence=True),
        validator=ChoiceValidator(keys, message="Выберите товар из списка (Tab)"),
    ).strip()
    return choices[picked]


def _prompt_existing_item(order_id: str) -> int | None:
    """Выбор одной из позиций заказа. Возвращает product_id."""
    items = _load_items(order_id)
    if not items:
        render_error("В заказе нет товаров")
        return None
    choices = {f"{item.sku} - {item.name}": item.product_id for item in items}
    keys = list(choices)
    picked = prompt(
        "Товар из заказа: ",
        completer=WordCompleter(keys, ignore_case=True, sentence=True),
        validator=ChoiceValidator(keys, message="Выберите товар из заказа (Tab)"),
    ).strip()
    return choices[picked]


def _add_single_item(order_id: str) -> bool:
    picked = _prompt_new_product(order_id)
    if picked is None:
        return False
    product_id, product_price = picked
    quantity = int(prompt("Количество: ", validator=PositiveIntValidator()).strip())
    price = Decimal(
        prompt(
            "Цена: ", default=f"{product_price:.2f}", validator=PriceValidator()
        ).strip()
    )
    conn = get_conn()
    conn.execute(
        """INSERT INTO sales.order_items (order_id, product_id, price, quantity)
        VALUES (%s, %s, %s, %s)""",
        (order_id, product_id, price, quantity),
    )
    _recalc_total(order_id)
    console.print("[green]Товар добавлен в заказ[/green]")
    return True


def _add_items_loop(order_id: str) -> None:
    """Интерактивно добавляет товары в заказ, спрашивая после каждого, нужно ли еще."""
    while True:
        answer = prompt(
            "Добавить товар в заказ? (y/n, д/н): ", validator=YesNoValidator()
        )
        if not YesNoValidator.is_yes(answer):
            return
        if not _add_single_item(order_id):
            return


@command("list orders", "список всех заказов", CATEGORY_ORDERS)
def list_orders() -> None:
    """Выводит список всех заказов."""
    conn = get_conn()
    table = Table(title="Заказы", show_header=True, header_style="bold cyan")
    table.add_column("ID", style="dim", width=6, justify="right")
    table.add_column("Статус", style="green", min_width=12)
    table.add_column("Сумма", style="yellow", justify="right", min_width=10)
    table.add_column("Создан", style="cyan", min_width=16)
    table.add_column("Склад", style="magenta", min_width=15)

    with conn.cursor() as cur:
        cur.execute("""SELECT o.id, o.status, o.total_amount, o.created_at, w.city
            FROM sales.orders o
            JOIN catalog.warehouses w ON w.id = o.warehouse_id
            ORDER BY o.id""")
        rows = cur.fetchall()

    for oid, status, total, created_at, city in rows:
        table.add_row(
            str(oid),
            status,
            f"{total:.2f}",
            created_at.strftime("%Y-%m-%d %H:%M"),
            city,
        )
    console.print(table)


@command("show order", "информация о заказе", CATEGORY_ORDERS)
def show_order(_id: str) -> None:
    """Показывает заказ и его позиции."""
    order = _find_order(_id)
    if order is None:
        render_error(f"Заказ с ID {_id} не найден")
        return
    _render_order(order)


@command("add order", "добавить заказ (интерактивно)", CATEGORY_ORDERS)
def add_order() -> None:
    """Создает заказ и предлагает сразу добавить в него товары."""
    conn = get_conn()
    warehouse_id = _prompt_warehouse()
    if warehouse_id is None:
        return

    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO sales.orders (warehouse_id) VALUES (%s) RETURNING id",
            (warehouse_id,),
        )
        order_id = cur.fetchone()[0]  # type: ignore[index]
    console.print(f"[green]Заказ #{order_id} создан[/green]")

    _add_items_loop(str(order_id))
    _recalc_total(str(order_id))
    show_order(str(order_id))


@command("edit order", "редактировать заказ", CATEGORY_ORDERS)
def edit_order(_id: str) -> None:
    """Редактирует заказ. Статус менять нельзя, задается только склад отгрузки."""
    conn = get_conn()
    order = _find_order(_id)
    if order is None:
        render_error(f"Заказ с ID {_id} не найден")
        return
    if not _ensure_unpublished(order):
        return

    warehouse_id = _prompt_warehouse(default=str(order.warehouse_id))
    if warehouse_id is None:
        return
    conn.execute(
        "UPDATE sales.orders SET warehouse_id = %s WHERE id = %s",
        (warehouse_id, _id),
    )
    console.print(f"[green]Заказ #{order.id} обновлен[/green]")


@command("delete order", "удалить заказ", CATEGORY_ORDERS)
def delete_order(_id: str) -> None:
    """Удаляет заказ вместе с его позициями."""
    conn = get_conn()
    order = _find_order(_id)
    if order is None:
        render_error(f"Заказ с ID {_id} не найден")
        return
    if not _ensure_unpublished(order):
        return

    _render_order(order)
    answer = prompt("Вы уверены? (y/n, д/н): ", validator=YesNoValidator())
    if not YesNoValidator.is_yes(answer):
        return

    conn.execute("DELETE FROM sales.orders WHERE id = %s", (_id,))
    console.print(f"[green]Заказ #{order.id} удален[/green]")


@command("publish order", "опубликовать заказ (unpublished -> new)", CATEGORY_ORDERS)
def publish_order(_id: str) -> None:
    """Меняет статус заказа с unpublished на new. После этого заказ неизменяем."""
    conn = get_conn()
    order = _find_order(_id)
    if order is None:
        render_error(f"Заказ с ID {_id} не найден")
        return
    if order.status != UNPUBLISHED:
        render_error(f"Заказ #{order.id} уже опубликован (статус {order.status})")
        return

    conn.execute("UPDATE sales.orders SET status = 'new' WHERE id = %s", (_id,))
    console.print(f"[green]Заказ #{order.id} опубликован (статус new)[/green]")


@command("add order_item", "добавить товар в заказ", CATEGORY_ORDERS)
def add_order_item(order_id: str) -> None:
    """Добавляет один или несколько товаров в существующий заказ."""
    order = _find_order(order_id)
    if order is None:
        render_error(f"Заказ с ID {order_id} не найден")
        return
    if not _ensure_unpublished(order):
        return

    _add_items_loop(order_id)
    show_order(order_id)


@command("edit order_item", "изменить товар в заказе", CATEGORY_ORDERS)
def edit_order_item(order_id: str) -> None:
    """Меняет цену и количество выбранной позиции заказа."""
    conn = get_conn()
    order = _find_order(order_id)
    if order is None:
        render_error(f"Заказ с ID {order_id} не найден")
        return
    if not _ensure_unpublished(order):
        return

    product_id = _prompt_existing_item(order_id)
    if product_id is None:
        return

    with conn.cursor() as cur:
        cur.execute(
            "SELECT price, quantity FROM sales.order_items "
            "WHERE order_id = %s AND product_id = %s",
            (order_id, product_id),
        )
        cur_price, cur_quantity = cur.fetchone()  # type: ignore[misc]

    quantity = int(
        prompt(
            "Количество: ",
            default=str(cur_quantity),
            validator=PositiveIntValidator(),
        ).strip()
    )
    price = Decimal(
        prompt("Цена: ", default=f"{cur_price:.2f}", validator=PriceValidator()).strip()
    )
    conn.execute(
        """UPDATE sales.order_items SET price = %s, quantity = %s
        WHERE order_id = %s AND product_id = %s""",
        (price, quantity, order_id, product_id),
    )
    _recalc_total(order_id)
    console.print("[green]Позиция заказа обновлена[/green]")


@command("delete order_item", "удалить товар из заказа", CATEGORY_ORDERS)
def delete_order_item(order_id: str) -> None:
    """Удаляет выбранную позицию из заказа."""
    conn = get_conn()
    order = _find_order(order_id)
    if order is None:
        render_error(f"Заказ с ID {order_id} не найден")
        return
    if not _ensure_unpublished(order):
        return

    product_id = _prompt_existing_item(order_id)
    if product_id is None:
        return
    conn.execute(
        "DELETE FROM sales.order_items WHERE order_id = %s AND product_id = %s",
        (order_id, product_id),
    )
    _recalc_total(order_id)
    console.print("[green]Позиция удалена из заказа[/green]")
