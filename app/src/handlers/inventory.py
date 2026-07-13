from prompt_toolkit import prompt
from prompt_toolkit.completion import WordCompleter
from rich.panel import Panel
from rich.table import Table

from console import console, render_error
from db import get_conn
from validators import ChoiceValidator, YesNoValidator
from auth import ROLE_INVENTORY_MANAGER, auth_user
from commands import command, CATEGORY_INVENTORY

_SELECT_ORDERS = """
    SELECT o.id, o.status, o.total_amount, o.created_at, u.username, c.name
    FROM sales.orders o
    JOIN catalog.warehouses w ON w.id = o.warehouse_id
    JOIN catalog.cities c ON c.id = w.city_id
    JOIN auth.users u ON u.id = o.created_by
"""


def _render_orders_table(title: str, rows: list) -> None:
    table = Table(title=title, show_header=True, header_style="bold cyan")
    table.add_column("ID", style="dim", width=6, justify="right")
    table.add_column("Статус", style="green", min_width=12)
    table.add_column("Сумма", style="yellow", justify="right", min_width=10)
    table.add_column("Создан", style="cyan", min_width=16)
    table.add_column("Создал", style="blue", min_width=10)
    table.add_column("Склад", style="magenta", min_width=15)

    for oid, status, total, created_at, username, city in rows:
        table.add_row(
            str(oid),
            status,
            f"{total:.2f}",
            created_at.strftime("%Y-%m-%d %H:%M"),
            username,
            city,
        )
    console.print(table)


@command(
    "list orders new",
    "новые заказы",
    CATEGORY_INVENTORY,
    [ROLE_INVENTORY_MANAGER],
)
def list_orders_new() -> None:
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute(_SELECT_ORDERS + " WHERE o.status = 'new' ORDER BY o.id")
        rows = cur.fetchall()
    _render_orders_table("Новые заказы", rows)


@command(
    "list orders processing",
    "заказы в обработке",
    CATEGORY_INVENTORY,
    [ROLE_INVENTORY_MANAGER],
)
def list_orders_processing() -> None:
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute(_SELECT_ORDERS + " WHERE o.status = 'processing' ORDER BY o.id")
        rows = cur.fetchall()
    _render_orders_table("Заказы в обработке", rows)


@command(
    "list orders my",
    "заказы, обработанные мной",
    CATEGORY_INVENTORY,
    [ROLE_INVENTORY_MANAGER],
)
def list_orders_my() -> None:
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute(
            _SELECT_ORDERS + " WHERE o.processing_by = %s ORDER BY o.id",
            (auth_user().id,),
        )
        rows = cur.fetchall()
    _render_orders_table("Мои заказы", rows)


@command(
    "mark order processing",
    "взять заказ в обработку",
    CATEGORY_INVENTORY,
    [ROLE_INVENTORY_MANAGER],
)
def mark_order_processing(_id: str) -> None:
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute(_SELECT_ORDERS + " WHERE o.id = %s", (_id,))
        row = cur.fetchone()

    if row is None:
        render_error(f"Заказ с ID {_id} не найден")
        return
    oid, status, total, created_at, username, city = row
    if status != "new":
        render_error(f"Заказ #{oid} нельзя взять в обработку: статус {status}")
        return

    info = Table(show_header=False, box=None, padding=(0, 2))
    info.add_column("Поле", style="bold cyan", width=15)
    info.add_column("Значение", style="white")
    info.add_row("ID", str(oid))
    info.add_row("Статус", status)
    info.add_row("Сумма", f"{total:.2f}")
    info.add_row("Создан", created_at.strftime("%Y-%m-%d %H:%M"))
    info.add_row("Создал", username)
    info.add_row("Склад", city)
    console.print(
        Panel(
            info,
            expand=False,
            title=f"[bold green]Заказ #{oid}[/bold green]",
            border_style="green",
        )
    )

    answer = prompt("Взять заказ в обработку? (y/n, д/н): ", validator=YesNoValidator())
    if not YesNoValidator.is_yes(answer):
        return

    conn.execute(
        "UPDATE sales.orders SET status = 'processing', processing_by = %s WHERE id = %s",
        (auth_user().id, _id),
    )
    console.print(f"[green]Заказ #{oid} взят в обработку[/green]")


def _prompt_warehouse_id() -> int | None:
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("""SELECT w.id, c.name, w.label
            FROM catalog.warehouses w
            JOIN catalog.cities c ON c.id = w.city_id
            ORDER BY w.id""")
        rows = cur.fetchall()
    if not rows:
        render_error("Нет ни одного склада")
        return None

    console.print("[dim]Склады:[/dim]")
    for wid, city, label in rows:
        suffix = f" ({label})" if label else ""
        console.print(f"  {wid}: {city}{suffix}")

    ids = [str(wid) for wid, _, _ in rows]
    answer = prompt(
        "Склад (id): ",
        validator=ChoiceValidator(ids, message="Укажите id склада из списка"),
    ).strip()
    return int(answer)


@command(
    "view warehouse stock",
    "остатки по складу",
    CATEGORY_INVENTORY,
    [ROLE_INVENTORY_MANAGER],
)
def view_warehouse_stock() -> None:
    conn = get_conn()
    warehouse_id = _prompt_warehouse_id()
    if warehouse_id is None:
        return

    # показываем все товары каталога, даже если их нет в стоке;
    # сток при резервировании уменьшается, поэтому всего = сток + резерв
    with conn.cursor() as cur:
        cur.execute(
            """SELECT p.sku, p.name,
                COALESCE(s.quantity, 0) + COALESCE(r.reserved, 0) AS total,
                COALESCE(r.reserved, 0) AS reserved,
                COALESCE(s.quantity, 0) AS available
            FROM catalog.products p
            LEFT JOIN inventory.stock s
                ON s.product_id = p.id AND s.warehouse_id = %s
            LEFT JOIN (
                SELECT product_id, SUM(quantity) AS reserved
                FROM inventory.reserves
                WHERE warehouse_id = %s
                GROUP BY product_id
            ) r ON r.product_id = p.id
            ORDER BY p.sku""",
            (warehouse_id, warehouse_id),
        )
        rows = cur.fetchall()

    table = Table(
        title=f"Остатки склада #{warehouse_id}",
        show_header=True,
        header_style="bold cyan",
    )
    table.add_column("SKU", style="cyan", min_width=12)
    table.add_column("Товар", style="green", min_width=20)
    table.add_column("Всего", style="white", justify="right", min_width=8)
    table.add_column("В резерве", style="yellow", justify="right", min_width=9)
    table.add_column("Доступно", style="magenta", justify="right", min_width=8)

    for sku, name, total, reserved, available in rows:
        table.add_row(sku, name, str(total), str(reserved), str(available))
    console.print(table)


def _prompt_product_id() -> int | None:
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("SELECT id, sku, name FROM catalog.products ORDER BY sku")
        rows = cur.fetchall()
    if not rows:
        render_error("Нет ни одного товара")
        return None

    choices = {f"{sku} - {name}": pid for pid, sku, name in rows}
    keys = list(choices)
    picked = prompt(
        "Товар: ",
        completer=WordCompleter(keys, ignore_case=True, sentence=True),
        validator=ChoiceValidator(keys, message="Выберите товар из списка (Tab)"),
    ).strip()
    return choices[picked]


@command(
    "view product stock",
    "остатки товара по складам",
    CATEGORY_INVENTORY,
    [ROLE_INVENTORY_MANAGER],
)
def view_product_stock() -> None:
    conn = get_conn()
    product_id = _prompt_product_id()
    if product_id is None:
        return

    # склады отсортированы по доступному количеству по убыванию
    with conn.cursor() as cur:
        cur.execute(
            """SELECT w.id, c.name, w.label,
                COALESCE(s.quantity, 0) + COALESCE(r.reserved, 0) AS total,
                COALESCE(r.reserved, 0) AS reserved,
                COALESCE(s.quantity, 0) AS available
            FROM catalog.warehouses w
            JOIN catalog.cities c ON c.id = w.city_id
            LEFT JOIN inventory.stock s
                ON s.warehouse_id = w.id AND s.product_id = %s
            LEFT JOIN (
                SELECT warehouse_id, SUM(quantity) AS reserved
                FROM inventory.reserves
                WHERE product_id = %s
                GROUP BY warehouse_id
            ) r ON r.warehouse_id = w.id
            ORDER BY available DESC, w.id""",
            (product_id, product_id),
        )
        rows = cur.fetchall()

    table = Table(
        title="Остатки по складам", show_header=True, header_style="bold cyan"
    )
    table.add_column("Склад", style="dim", width=6, justify="right")
    table.add_column("Город", style="green", min_width=15)
    table.add_column("Метка", style="magenta", min_width=12)
    table.add_column("Всего", style="white", justify="right", min_width=8)
    table.add_column("В резерве", style="yellow", justify="right", min_width=9)
    table.add_column("Доступно", style="cyan", justify="right", min_width=8)

    for wid, city, label, total, reserved, available in rows:
        table.add_row(
            str(wid), city, label or "", str(total), str(reserved), str(available)
        )
    console.print(table)
