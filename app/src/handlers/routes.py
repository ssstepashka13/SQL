from dataclasses import dataclass
from datetime import timedelta
from decimal import Decimal

from prompt_toolkit import prompt
from prompt_toolkit.shortcuts import choice
from psycopg.rows import class_row
from rich.panel import Panel
from rich.table import Table

from console import console, render_error
from db import get_conn
from validators import PriceValidator, TimeValidator, YesNoValidator
from auth import ROLE_INVENTORY_MANAGER
from commands import command, CATEGORY_ROUTES


@dataclass
class Route:
    from_city_id: int
    to_city_id: int
    from_city: str
    to_city: str
    duration: timedelta
    total_threshold: Decimal


_SELECT_ROUTE = """
    SELECT r.from_city_id, r.to_city_id, cf.name AS from_city, ct.name AS to_city,
        r.duration, r.total_threshold
    FROM inventory.routes r
    JOIN catalog.cities cf ON cf.id = r.from_city_id
    JOIN catalog.cities ct ON ct.id = r.to_city_id
"""


def _fmt_duration(duration: timedelta) -> str:
    total = int(duration.total_seconds())
    hours, rest = divmod(total, 3600)
    minutes, seconds = divmod(rest, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"
    return f"{minutes:02d}:{seconds:02d}"


def _parse_duration(text: str) -> timedelta:
    parts = [int(p) for p in text.split(":")]
    if len(parts) == 2:
        return timedelta(minutes=parts[0], seconds=parts[1])
    return timedelta(hours=parts[0], minutes=parts[1], seconds=parts[2])


def _render_route(route: Route) -> None:
    table = Table(show_header=False, box=None, padding=(0, 2))
    table.add_column("Поле", style="bold cyan", width=15)
    table.add_column("Значение", style="white")

    table.add_row("Откуда", route.from_city)
    table.add_row("Куда", route.to_city)
    table.add_row("Время в пути", _fmt_duration(route.duration))
    table.add_row("Мин. сумма", f"{route.total_threshold:.2f}")

    panel = Panel(
        table,
        expand=False,
        title=f"[bold green]Маршрут {route.from_city} - {route.to_city}[/bold green]",
        border_style="green",
    )
    console.print(panel)


def _pick(message: str, names: list[str]) -> str:
    return choice(message, options=[(name, name) for name in names])


def _prompt_existing_route() -> Route | None:
    """Выбор существующего маршрута парой выпадающих списков городов."""
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("""SELECT DISTINCT c.name FROM inventory.routes r
            JOIN catalog.cities c ON c.id = r.from_city_id ORDER BY c.name""")
        from_names = [row[0] for row in cur.fetchall()]
    if not from_names:
        render_error("Маршрутов пока нет. Добавьте маршрут: add route")
        return None

    from_city = _pick("Город отправления: ", from_names)

    with conn.cursor() as cur:
        cur.execute(
            """SELECT ct.name FROM inventory.routes r
            JOIN catalog.cities cf ON cf.id = r.from_city_id
            JOIN catalog.cities ct ON ct.id = r.to_city_id
            WHERE cf.name = %s ORDER BY ct.name""",
            (from_city,),
        )
        to_names = [row[0] for row in cur.fetchall()]
    to_city = _pick("Город назначения: ", to_names)

    with conn.cursor(row_factory=class_row(Route)) as cur:
        cur.execute(
            _SELECT_ROUTE + " WHERE cf.name = %s AND ct.name = %s",
            (from_city, to_city),
        )
        return cur.fetchone()


@command(
    "list routes",
    "список маршрутов перемещения",
    CATEGORY_ROUTES,
    [ROLE_INVENTORY_MANAGER],
)
def list_routes() -> None:
    conn = get_conn()
    table = Table(title="Маршруты", show_header=True, header_style="bold cyan")
    table.add_column("Откуда", style="green", min_width=15)
    table.add_column("Куда", style="green", min_width=15)
    table.add_column("Время в пути", style="cyan", justify="right", min_width=12)
    table.add_column("Мин. сумма", style="yellow", justify="right", min_width=12)

    with conn.cursor(row_factory=class_row(Route)) as cur:
        cur.execute(_SELECT_ROUTE + " ORDER BY cf.name, ct.name")
        routes: list[Route] = cur.fetchall()

    for route in routes:
        table.add_row(
            route.from_city,
            route.to_city,
            _fmt_duration(route.duration),
            f"{route.total_threshold:.2f}",
        )
    console.print(table)


@command(
    "show route",
    "информация о маршруте",
    CATEGORY_ROUTES,
    [ROLE_INVENTORY_MANAGER],
)
def show_route() -> None:
    route = _prompt_existing_route()
    if route is None:
        return
    _render_route(route)


@command(
    "add route",
    "добавить маршрут (интерактивно)",
    CATEGORY_ROUTES,
    [ROLE_INVENTORY_MANAGER],
)
def add_route() -> None:
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("SELECT name FROM catalog.cities ORDER BY name")
        all_names = [row[0] for row in cur.fetchall()]

    from_city = _pick("Город отправления: ", all_names)

    # города, в которые маршрута из выбранного города еще нет
    with conn.cursor() as cur:
        cur.execute(
            """SELECT c.name FROM catalog.cities c
            WHERE c.name <> %s
              AND NOT EXISTS (
                SELECT 1 FROM inventory.routes r
                JOIN catalog.cities cf ON cf.id = r.from_city_id
                WHERE cf.name = %s AND r.to_city_id = c.id
              )
            ORDER BY c.name""",
            (from_city, from_city),
        )
        to_names = [row[0] for row in cur.fetchall()]
    if not to_names:
        render_error(f"Из города {from_city} маршруты во все города уже заданы")
        return
    to_city = _pick("Город назначения: ", to_names)

    duration = _parse_duration(
        prompt("Время в пути (MM:SS или HH:MM:SS): ", validator=TimeValidator()).strip()
    )
    threshold = prompt("Мин. сумма для отправки: ", validator=PriceValidator()).strip()

    conn.execute(
        """INSERT INTO inventory.routes (from_city_id, to_city_id, duration, total_threshold)
        SELECT cf.id, ct.id, %s, %s FROM catalog.cities cf, catalog.cities ct
        WHERE cf.name = %s AND ct.name = %s""",
        (duration, threshold, from_city, to_city),
    )
    console.print(f"[green]Маршрут {from_city} - {to_city} добавлен[/green]")


@command(
    "edit route",
    "редактировать маршрут",
    CATEGORY_ROUTES,
    [ROLE_INVENTORY_MANAGER],
)
def edit_route() -> None:
    conn = get_conn()
    route = _prompt_existing_route()
    if route is None:
        return

    duration = _parse_duration(
        prompt(
            "Время в пути (MM:SS или HH:MM:SS): ",
            default=_fmt_duration(route.duration),
            validator=TimeValidator(),
        ).strip()
    )
    threshold = prompt(
        "Мин. сумма для отправки: ",
        default=f"{route.total_threshold:.2f}",
        validator=PriceValidator(),
    ).strip()

    conn.execute(
        """UPDATE inventory.routes SET duration = %s, total_threshold = %s
        WHERE from_city_id = %s AND to_city_id = %s""",
        (duration, threshold, route.from_city_id, route.to_city_id),
    )
    console.print(
        f"[green]Маршрут {route.from_city} - {route.to_city} обновлен[/green]"
    )


@command(
    "delete route",
    "удалить маршрут",
    CATEGORY_ROUTES,
    [ROLE_INVENTORY_MANAGER],
)
def delete_route() -> None:
    conn = get_conn()
    route = _prompt_existing_route()
    if route is None:
        return

    _render_route(route)
    answer = prompt("Вы уверены? (y/n, д/н): ", validator=YesNoValidator())
    if not YesNoValidator.is_yes(answer):
        return

    conn.execute(
        "DELETE FROM inventory.routes WHERE from_city_id = %s AND to_city_id = %s",
        (route.from_city_id, route.to_city_id),
    )
    console.print(f"[green]Маршрут {route.from_city} - {route.to_city} удален[/green]")
