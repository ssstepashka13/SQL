"""create sales schema with orders and order_items

Revision ID: 30b0202b4409
Revises: 46c2b92c944e
Create Date: 2026-07-01 17:57:24.133549

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '30b0202b4409'
down_revision: Union[str, None] = '46c2b92c944e'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with open(f"alembic/sql/{revision}/up.sql") as file:
        op.execute(file.read())


def downgrade() -> None:
    with open(f"alembic/sql/{revision}/down.sql") as file:
        op.execute(file.read())